ExUnit.start(capture_log: true)

defmodule SSI.TestCluster do
  @moduledoc "Boots extra BEAM nodes running the full SSI application (hosted mode)."

  def start_peers(names) do
    # Members stopped by earlier tests would count against quorum.
    forget_absent()
    # Peers must present the cluster-derived cookie the SSI application uses.
    cookie = [~c"-setcookie", Atom.to_charlist(SSI.Cluster.Identity.cookie())]
    paths = cookie ++ Enum.flat_map(:code.get_path(), &[~c"-pa", &1])

    for name <- names do
      {:ok, pid, node} =
        :peer.start_link(%{name: name, host: ~c"127.0.0.1", longnames: true, args: paths, wait_boot: 30_000})

      dir = Path.join(System.tmp_dir!(), "ssi-test-#{name}-#{System.unique_integer([:positive])}")
      :ok = :erpc.call(node, Application, :put_env, [:logger, :level, :warning])
      :ok = :erpc.call(node, Logger, :configure, [[level: :warning]])
      :ok = :erpc.call(node, Application, :put_env, [:ssi, :data_dir, dir])
      :ok = :erpc.call(node, Application, :put_env, [:ssi, :autostart_services, false])
      {:ok, _} = :erpc.call(node, Application, :ensure_all_started, [:ssi])
      {pid, node}
    end
  end

  def stop_peers(peers) do
    for {pid, _} <- peers do
      try do
        :peer.stop(pid)
      catch
        :exit, _ -> :already_stopped
      end
    end

    forget_absent()
  end

  @doc """
  Drop members that are gone from the roster, so peers stopped by earlier
  tests (or earlier runs: the hosted store persists) do not count against
  quorum in later ones.
  """
  def forget_absent do
    eventually(fn ->
      members = SSI.Cluster.members()
      for e <- SSI.Cluster.Roster.all(), e.node not in members, do: SSI.Cluster.Roster.forget(e.id)
      SSI.Cluster.Roster.quorum().absent == []
    end)
  end

  @doc "Poll `fun` until it returns truthy or `ms` elapses."
  def eventually(fun, ms \\ 10_000) do
    deadline = System.monotonic_time(:millisecond) + ms
    loop(fun, deadline)
  end

  defp loop(fun, deadline) do
    case fun.() do
      falsy when falsy in [nil, false] ->
        if System.monotonic_time(:millisecond) > deadline do
          raise ExUnit.AssertionError, message: "condition not met in time"
        else
          Process.sleep(100)
          loop(fun, deadline)
        end

      value ->
        value
    end
  end
end

SSI.TestCluster.forget_absent()
