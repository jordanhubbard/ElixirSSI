defmodule SSI.Power do
  @moduledoc """
  Orderly restart and power-off, for one member or the whole system.

  Shutting down a member stops its services first so they checkpoint and
  fail over while the node is still reachable, then syncs and calls
  reboot(2). Because the BEAM is PID 1 it must never simply exit: the kernel
  would panic. Hosted nodes only log the request.
  """
  require Logger

  def restart(target \\ :local), do: act(target, :restart)
  def poweroff(target \\ :local), do: act(target, :poweroff)

  defp act(:all, how) do
    for n <- SSI.Cluster.peers(), do: :erpc.cast(n, __MODULE__, :local, [how])
    local(how)
  end

  defp act(:local, how), do: local(how)

  defp act(host, how) do
    n = SSI.Proc.resolve_node(host)
    if n == node(), do: local(how), else: :erpc.cast(n, __MODULE__, :local, [how])
  end

  @doc false
  def local(how) do
    Logger.warning("power: #{how} requested on #{SSI.Boot.hostname()}")

    if SSI.Sys.target?() do
      Task.start(fn ->
        # Leave the cluster cleanly: services hand off, then the node goes.
        _ = Supervisor.terminate_child(SSI.Supervisor, SSI.Service.Manager)
        DynamicSupervisor.which_children(SSI.Service.Sup)
        |> Enum.each(fn {_, pid, _, _} -> GenServer.stop(pid, {:shutdown, :poweroff}, 5_000) end)
        Process.sleep(500)
        SSI.Status.BootRecord.ended(how)
        SSI.Sys.sync()
        SSI.Sys.reboot(how)
      end)

      :ok
    else
      {:error, :hosted}
    end
  end
end
