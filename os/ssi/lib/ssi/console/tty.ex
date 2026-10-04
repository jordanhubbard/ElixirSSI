defmodule SSI.Console.TTY do
  @moduledoc """
  The system shell on a virtual console — on a CM5, the HDMI display and a
  USB keyboard.

  The serial console is the BEAM's own terminal. This service opens a second
  one (`console.tty`, default `tty1`) through `SSI.Sys.open_tty/1`, reads and
  writes it as an Erlang fd port (so no scheduler blocks on it), and runs an
  IEx shell whose group leader is an `SSI.Console.IOServer` over that port.
  When the shell exits it is started again.
  """
  use GenServer
  require Logger

  def start_link(_), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @impl true
  def init(_) do
    tty = SSI.Config.get("console.tty", "tty1")
    path = "/dev/" <> tty

    with true <- SSI.Sys.target?() and tty != "off" and File.exists?(path),
         {:ok, fd} <- SSI.Sys.open_tty(path) do
      port = Port.open({:fd, fd, fd}, [:binary, :stream])
      # Keep the screen on: a console no one is typing at must stay readable.
      Port.command(port, "\e[9;0]\e[14;0]\e[H\e[J")
      {:ok, io} = SSI.Console.IOServer.start_link(&Port.command(port, &1))
      shell = spawn_link(fn -> shell_loop(io) end)
      Logger.info("console: shell on #{path}")
      {:ok, %{port: port, io: io, shell: shell, tty: tty}}
    else
      _ -> :ignore
    end
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    SSI.Console.IOServer.feed(state.io, data)
    {:noreply, state}
  end

  def handle_info(_, state), do: {:noreply, state}

  defp shell_loop(io) do
    Process.group_leader(self(), io)
    IO.puts(SSI.Shell.motd())
    dot_iex = if File.exists?("/root/.iex.exs"), do: "/root/.iex.exs", else: ""
    IEx.Server.run(dot_iex: dot_iex, register: false, prefix: "tty")
    shell_loop(io)
  end
end
