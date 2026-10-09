defmodule ElixirSSI.Command.Store do
  @moduledoc "Durable command-node configuration, independent of managed guests."
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  def get, do: GenServer.call(__MODULE__, :get)
  def update(fun), do: GenServer.call(__MODULE__, {:update, fun})
  def directory, do: Application.fetch_env!(:ssi_command, :data_dir)

  @impl true
  def init(_) do
    File.mkdir_p!(directory())
    path = Path.join(directory(), "configuration.json")

    state =
      if File.exists?(path),
        do: Jason.decode!(File.read!(path)),
        else: %{"nodes" => 3, "memory" => 4096, "physical" => [], "operations" => []}

    {:ok, state}
  end

  @impl true
  def handle_call(:get, _, state), do: {:reply, state, state}

  def handle_call({:update, fun}, _, state) do
    next = fun.(state)
    path = Path.join(directory(), "configuration.json")
    File.write!(path <> ".tmp", Jason.encode!(next))
    File.chmod!(path <> ".tmp", 0o600)
    File.rename!(path <> ".tmp", path)
    Phoenix.PubSub.broadcast(ElixirSSI.Command.PubSub, "command", :changed)
    {:reply, :ok, next}
  end
end
