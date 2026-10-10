defmodule SSI.Application do
  @moduledoc """
  The operating system's supervision tree.

  Boot order is the child order: devices and network first, then BEAM
  distribution (which needs an address), then the replicated state that
  depends on it, then the services built on that state, and last the ways in
  — the status endpoint, SSH and the console banner. Every component is supervised; a crash in one
  restarts it rather than the machine.
  """
  use Application


  @impl true
  def start(_type, _args) do
    SSI.Boot.run()

    children = [
      SSI.Events,
      %{id: :pg, start: {:pg, :start_link, [SSI.Service.scope()]}},
      SSI.Devices,
      SSI.Net,
      SSI.Cluster.Distribution,
      SSI.Load,
      SSI.Cluster,
      SSI.Store,
      SSI.Blob,
      {Task.Supervisor, name: SSI.TaskSup},
      SSI.FS.Cluster,
      SSI.Cluster.Discovery,
      SSI.Status.Journal,
      {DynamicSupervisor, name: SSI.Service.Sup, strategy: :one_for_one},
      SSI.Service.Manager,
      SSI.Deploy,
      SSI.WorkspaceFiles,
      SSI.Web,
      SSI.SSH,
      SSI.Console.TTY,
      SSI.Console
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: SSI.Supervisor, max_restarts: 10, max_seconds: 10)
  end
end

defmodule SSI.Console do
  @moduledoc "Prints the banner on the system console once the system is up, and registers boot-configured services."
  use GenServer, restart: :transient

  def start_link(_), do: GenServer.start_link(__MODULE__, [])

  @impl true
  def init(_) do
    if Application.get_env(:ssi, :autostart_services, true), do: SSI.Desktop.autostart()
    if SSI.Sys.target?(), do: IO.puts(SSI.Shell.motd())
    :ignore
  end
end
