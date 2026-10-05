defmodule SSI.Service do
  @moduledoc """
  Cluster services: named, location-independent, highly available processes.

  A service is any `GenServer` module registered cluster-wide with
  `register/4`. Exactly one instance runs on one member; which member is a
  pure function of the service name and the membership (rendezvous hashing),
  or the member it is pinned to. Every node's `SSI.Service.Manager` evaluates
  that function whenever membership or the service table changes and starts
  or stops its local instances accordingly — there is no leader to elect.

  When the owning member fails, the next-ranked member starts the service.
  `move/2` migrates a running service: the old instance checkpoints and stops,
  then the new owner starts it from that checkpoint. Services persist state
  with `checkpoint/2` and recover it with `restore/1`; checkpoints are
  replicated synchronously so the next owner always sees the latest one.

      defmodule Counter do
        use GenServer
        def start_link(args), do: GenServer.start_link(__MODULE__, args)
        def init(%{ssi_service: name}), do: {:ok, SSI.Service.restore(name) || 0}
        def handle_call(:inc, _, n), do: {:reply, n + 1, n + 1}
        def terminate(_, n), do: SSI.Service.checkpoint(:counter, n)
      end

      SSI.Service.register(:counter, Counter)
      SSI.Service.call(:counter, :inc)
      SSI.Service.move(:counter, :"ssi@169.254.4.7")

  Under a network partition only the side holding quorum
  (`SSI.Cluster.Roster`) runs services: a group that loses quorum stops its
  instances and the other side starts them. Without quorum a service has no
  owner.
  """

  @scope :ssi

  @doc "Register (or replace) a service. `args` must be a map."
  def register(name, module, args \\ %{}, opts \\ []) do
    SSI.Store.put_sync(:services, name, %{
      module: module,
      args: args,
      pinned: opts[:node],
      registered_at: System.os_time(:second)
    })
  end

  def unregister(name), do: SSI.Store.delete(:services, name)

  def spec(name), do: SSI.Store.get(:services, name)

  @doc "All services with their current location."
  def list do
    for {name, spec} <- SSI.Store.all(:services) |> Enum.sort() do
      pid = whereis(name)
      %{name: name, module: spec.module, pinned: spec.pinned, pid: pid, node: pid && node(pid), owner: owner(name)}
    end
  end

  @doc "Pid of the running instance, wherever it is."
  def whereis(name) do
    case :pg.get_members(@scope, {:ssi_service, name}) do
      [pid | _] -> pid
      [] -> nil
    end
  end

  def call(name, msg, timeout \\ 5_000) do
    case whereis(name) do
      nil -> {:error, :not_running}
      pid -> GenServer.call(pid, msg, timeout)
    end
  end

  def cast(name, msg) do
    if pid = whereis(name), do: GenServer.cast(pid, msg)
    :ok
  end

  @doc "Persist service state cluster-wide (synchronously)."
  def checkpoint(name, state), do: SSI.Store.put_sync(:service_state, name, state)

  def restore(name), do: SSI.Store.get(:service_state, name)

  @doc "Migrate a service to `node` (a node or host name); `nil` unpins it."
  def move(name, node) do
    node = node && SSI.Proc.resolve_node(node)

    case spec(name) do
      nil -> {:error, :unknown_service}
      spec -> SSI.Store.put_sync(:services, name, %{spec | pinned: node})
    end
  end

  @doc "The member that should run `name` under the current membership (nil without quorum)."
  def owner(name, members \\ SSI.Cluster.members()) do
    owner(name, members, SSI.Cluster.Roster.quorum?(members))
  end

  @doc false
  def owner(name, members, quorum) do
    case spec(name) do
      nil ->
        nil

      _ when not quorum ->
        nil

      %{pinned: pinned} when pinned != nil ->
        if pinned in members, do: pinned, else: rank(name, members)

      _ ->
        rank(name, members)
    end
  end

  defp rank(name, members) do
    Enum.max_by(members, &:crypto.hash(:sha256, [:erlang.term_to_binary(name), Atom.to_string(&1)]))
  end

  @doc false
  def scope, do: @scope
end

defmodule SSI.Service.Manager do
  @moduledoc "Per-node reconciler that runs the services this node owns."
  use GenServer
  require Logger

  @tick 5_000

  # A freshly booted node has not yet heard the cluster's beacons and would
  # believe it owns every service. It waits this long (several beacon and
  # anti-entropy intervals) before claiming any.
  @settle_ms 8_000

  def start_link(_), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @doc "Names of services running on this node."
  def local, do: GenServer.call(__MODULE__, :local)

  @impl true
  def init(_) do
    SSI.Events.subscribe(:membership)
    SSI.Store.subscribe(:services)
    SSI.Store.subscribe(SSI.Cluster.Roster.table())
    settle = Application.get_env(:ssi, :service_settle_ms, if(SSI.Sys.target?(), do: @settle_ms, else: 0))
    Process.send_after(self(), :settled, settle)
    {:ok, %{running: %{}, starting: MapSet.new(), settled: false}}
  end

  @impl true
  def handle_call(:local, _from, state), do: {:reply, Map.keys(state.running), state}

  @impl true
  def handle_info(:settled, state) do
    send(self(), :reconcile)
    {:noreply, %{state | settled: true}}
  end

  # Until settled, membership and store events are ignored; the first
  # reconcile happens on :settled with a converged view.
  def handle_info(_msg, %{settled: false} = state), do: {:noreply, state}

  def handle_info(:reconcile, state) do
    Process.send_after(self(), :reconcile, @tick)
    {:noreply, reconcile(state)}
  end

  def handle_info({:ssi_membership, _, _}, state), do: {:noreply, reconcile(state)}
  def handle_info({:ssi_store, table, _, _}, state) when table in [:services, :roster], do: {:noreply, reconcile(state)}

  def handle_info({:started, name, {:ok, pid}}, state) do
    Process.monitor(pid)
    :pg.join(SSI.Service.scope(), {:ssi_service, name}, pid)
    Logger.info("service: #{inspect(name)} started on #{SSI.Boot.hostname()}")
    SSI.Status.Journal.service_started(name)
    {:noreply, %{state | running: Map.put(state.running, name, pid), starting: MapSet.delete(state.starting, name)}}
  end

  def handle_info({:started, name, error}, state) do
    Logger.error("service: #{inspect(name)} failed to start: #{inspect(error)}")
    {:noreply, %{state | starting: MapSet.delete(state.starting, name)}}
  end

  def handle_info({:DOWN, _, :process, pid, reason}, state) do
    case Enum.find(state.running, fn {_, p} -> p == pid end) do
      {name, _} ->
        unless reason in [:normal, :shutdown] or match?({:shutdown, _}, reason),
          do: Logger.warning("service: #{inspect(name)} exited: #{inspect(reason)}")

        SSI.Status.Journal.service_stopped(name, reason)

        # Restarted by the next reconcile if this node still owns it.
        Process.send_after(self(), :reconcile, 1_000)
        {:noreply, %{state | running: Map.delete(state.running, name)}}

      nil ->
        {:noreply, state}
    end
  end

  def handle_info(_, state), do: {:noreply, state}

  defp reconcile(state) do
    SSI.Cluster.Roster.enroll()
    members = SSI.Cluster.members()
    specs = Map.new(SSI.Store.all(:services))
    quorum = SSI.Cluster.Roster.quorum?(members)

    if quorum != Map.get(state, :quorum, true) do
      if quorum,
        do: Logger.warning("service: quorum regained on #{SSI.Boot.hostname()}; running services"),
        else: Logger.warning("service: quorum lost on #{SSI.Boot.hostname()}; stopping services")

      SSI.Status.Journal.quorum(quorum)
    end

    # Stop what we run but no longer own (or that was unregistered).
    running =
      Enum.reduce(state.running, state.running, fn {name, pid}, acc ->
        if Map.has_key?(specs, name) and SSI.Service.owner(name, members, quorum) == node() do
          acc
        else
          why = if(quorum, do: :moved, else: :no_quorum)
          Logger.info("service: #{inspect(name)} #{if quorum, do: "handing off", else: "stopping"} on #{SSI.Boot.hostname()}")
          # Recorded here: the instance leaves `running` before its exit arrives.
          SSI.Status.Journal.service_stopped(name, {:shutdown, why})
          stop(pid, why)
          Map.delete(acc, name)
        end
      end)

    # Start what we own but do not run. The start waits until no other
    # instance is alive, so a migrating service restores its final checkpoint.
    starting =
      Enum.reduce(specs, state.starting, fn {name, spec}, acc ->
        if SSI.Service.owner(name, members, quorum) == node() and not Map.has_key?(running, name) and
             not MapSet.member?(acc, name) do
          start_async(name, spec)
          MapSet.put(acc, name)
        else
          acc
        end
      end)

    %{state | running: running, starting: starting} |> Map.put(:quorum, quorum)
  end

  defp stop(pid, why) do
    Task.start(fn ->
      try do
        GenServer.stop(pid, {:shutdown, why}, 15_000)
      catch
        :exit, _ -> Process.exit(pid, :kill)
      end
    end)
  end

  defp start_async(name, spec) do
    manager = self()

    Task.start(fn ->
      await_unowned(name, 50)
      args = Map.put(spec.args, :ssi_service, name)

      result =
        try do
          DynamicSupervisor.start_child(SSI.Service.Sup, %{
            id: name,
            start: {spec.module, :start_link, [args]},
            restart: :temporary,
            shutdown: 10_000
          })
        catch
          kind, reason -> {:error, {kind, reason}}
        end

      send(manager, {:started, name, result})
    end)
  end

  defp await_unowned(_name, 0), do: :ok

  defp await_unowned(name, tries) do
    if SSI.Service.whereis(name) do
      Process.sleep(200)
      await_unowned(name, tries - 1)
    end
  end
end
