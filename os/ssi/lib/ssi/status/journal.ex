defmodule SSI.Status.Journal do
  @moduledoc """
  The member's recent history, for the monitor's timeline.

  Two kinds of event are kept, newest last, up to 200 of them:

    * *observations* this member makes itself — another member joining or
      leaving — which stay local, since every member observes them;
    * *originated* events — a service starting or stopping here, this member
      booting, a monitor request this member carried out — which are sent to every member as they happen, and again to
      each member that joins, so any member's journal tells the cluster's
      story. Ids (`HOST-BOOT-SEQ`) are unique across the cluster, so copies
      merge.

  A service start that replaces an instance on a member that has since left
  is a failover; the event carries how long the service was unavailable,
  measured from the last load sample this member heard from the lost member.
  """
  use GenServer

  @max 200
  @table :ssi_journal
  @tick 1_000
  @alive_ms 30_000

  def start_link(_), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @doc "Recent events, oldest first."
  def recent do
    case :ets.whereis(@table) do
      :undefined -> []
      _ -> :ets.tab2list(@table) |> Enum.map(&elem(&1, 1))
    end
  end

  @doc "Record that service `name` started on this member."
  def service_started(name), do: GenServer.cast(__MODULE__, {:service, :started, name, nil})

  @doc "Record that service `name` stopped on this member, and why."
  def service_stopped(name, reason), do: GenServer.cast(__MODULE__, {:service, :stopped, name, reason})

  @doc "Record an authenticated monitor request about `subject` (`SSI.Web.Control`)."
  def control(subject, detail), do: GenServer.cast(__MODULE__, {:control, subject, detail})

  @doc "Events are published locally on this topic as `{:ssi_journal, event}`."
  def topic, do: :journal

  # -- server -----------------------------------------------------------------

  @impl true
  def init(_) do
    :ets.new(@table, [:named_table, :protected, :ordered_set, read_concurrency: true])
    SSI.Events.subscribe(:membership)
    send(self(), :tick)
    Process.send_after(self(), :alive, @alive_ms)

    state = %{own: [], heard: %{}, left: %{}, names: %{}, locations: %{}}
    previous = SSI.Status.BootRecord.previous()
    {:ok, originate(state, "member_booted", SSI.Boot.hostname(), %{previous_boot: previous})}
  end

  @impl true
  def handle_cast({:service, :started, name, _}, state) do
    label = SSI.Status.label(name)

    detail =
      case state.locations[label] do
        nil ->
          %{how: "started"}

        prev when prev == node() ->
          %{how: "restarted"}

        prev ->
          from = name(state, prev)

          if prev in SSI.Cluster.members() do
            %{how: "migrated", from: from}
          else
            # Measured from its last load sample, or else from when this
            # member saw it leave (which omits the detection time).
            heard = Map.get(state.heard, prev) || Map.get(state.left, prev)
            gap = if heard, do: System.os_time(:millisecond) - heard
            %{how: "failover", from: from, unavailable_ms: gap}
          end
      end

    state = %{state | locations: Map.put(state.locations, label, node())}
    {:noreply, originate(state, "service_started", label, detail)}
  end

  def handle_cast({:service, :stopped, name, reason}, state) do
    {:noreply, originate(state, "service_stopped", SSI.Status.label(name), %{reason: reason_text(reason)})}
  end

  def handle_cast({:control, subject, detail}, state) do
    {:noreply, originate(state, "control", subject, detail)}
  end

  def handle_cast({:events, events}, state) do
    Enum.each(events, &insert/1)

    # Where services started elsewhere is known at once, not at the next tick.
    locations =
      for %{kind: "service_started", subject: s, node: n} <- events, reduce: state.locations do
        acc -> Map.put(acc, s, n)
      end

    {:noreply, %{state | locations: locations}}
  end

  @impl true
  def handle_info(:tick, state) do
    # Remember who was last heard when, and where each service ran, so the
    # departures and failovers that follow can be described.
    loads = SSI.Load.cluster()
    heard = Enum.reduce(loads, state.heard, fn s, acc -> Map.put(acc, s.node, s.at) end)
    names = Enum.reduce(SSI.Cluster.cached_infos(), state.names, &Map.put(&2, &1.node, &1.hostname))

    locations =
      Enum.reduce(SSI.Service.list(), state.locations, fn
        %{node: nil}, acc -> acc
        %{name: name, node: n}, acc -> Map.put(acc, SSI.Status.label(name), n)
      end)

    Process.send_after(self(), :tick, @tick)
    {:noreply, %{state | heard: heard, names: names, locations: locations}}
  end

  def handle_info(:alive, state) do
    SSI.Status.BootRecord.alive()
    Process.send_after(self(), :alive, @alive_ms)
    {:noreply, state}
  end

  def handle_info({:ssi_membership, :up, node}, state) do
    # A member that joins hears this member's story so far.
    GenServer.cast({__MODULE__, node}, {:events, Enum.reverse(state.own)})
    {:noreply, observe(state, "member_joined", name(state, node), %{node: node})}
  end

  def handle_info({:ssi_membership, :down, node}, state) do
    state = %{state | left: Map.put(state.left, node, System.os_time(:millisecond))}
    detail = %{node: node, last_heard: Map.get(state.heard, node)}
    {:noreply, observe(state, "member_left", name(state, node), detail)}
  end

  def handle_info(_, state), do: {:noreply, state}

  # -- events -------------------------------------------------------------------

  defp originate(state, kind, subject, detail) do
    {event, state} = event(state, kind, subject, detail)
    GenServer.abcast(Node.list(), __MODULE__, {:events, [event]})
    %{state | own: Enum.take([event | state.own], @max)}
  end

  defp observe(state, kind, subject, detail) do
    {_event, state} = event(state, kind, subject, detail)
    state
  end

  defp event(state, kind, subject, detail) do
    # Unique for the life of this BEAM, even across restarts of the journal.
    seq = :erlang.unique_integer([:positive, :monotonic])

    event = %{
      id: "#{SSI.Boot.hostname()}-#{SSI.Status.BootRecord.boot_id()}-#{seq}",
      at: System.os_time(:millisecond),
      kind: kind,
      subject: subject,
      origin: SSI.Boot.hostname(),
      node: node(),
      detail: detail
    }

    insert(event)
    {event, state}
  end

  defp insert(%{id: id, at: at} = event) do
    unless :ets.match_object(@table, {{:_, id}, :_}) != [] do
      :ets.insert(@table, {{at, id}, event})
      trim()
      SSI.Events.publish(:journal, {:ssi_journal, event})
    end
  end

  defp trim do
    if :ets.info(@table, :size) > @max, do: :ets.delete(@table, :ets.first(@table))
  end

  defp name(state, node) do
    Map.get(state.names, node) ||
      Enum.find_value(SSI.Cluster.cached_infos(), host(node), &(&1.node == node && &1.hostname))
  end

  defp host(node), do: node |> to_string() |> String.split("@") |> List.last()

  defp reason_text(nil), do: "stopped"
  defp reason_text(:normal), do: "stopped"
  defp reason_text(:shutdown), do: "stopped"
  defp reason_text({:shutdown, :moved}), do: "handed off"
  defp reason_text({:shutdown, :poweroff}), do: "member shutting down"
  defp reason_text({:shutdown, r}), do: inspect(r)
  defp reason_text(r), do: "crashed: " <> String.slice(inspect(r), 0, 200)
end
