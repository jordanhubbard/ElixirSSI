defmodule ElixirSSI.Command.Cluster do
  @moduledoc "Observe physical and emulated members without depending on their availability."
  use GenServer
  alias ElixirSSI.Command.{Instances, Store}
  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  def snapshot, do: GenServer.call(__MODULE__, :snapshot)

  def forget(endpoint),
    do: Store.update(&Map.update!(&1, "physical", fn nodes -> List.delete(nodes, endpoint) end))

  def register(address) do
    uri = URI.parse(String.trim(address))

    if uri.scheme in ["http", "https"] and is_binary(uri.host) and uri.host != "" and
         is_nil(uri.userinfo) and is_nil(uri.query) and is_nil(uri.fragment) and
         uri.path in [nil, "", "/"] do
      endpoint = String.trim_trailing(URI.to_string(uri), "/")
      Store.update(&Map.update!(&1, "physical", fn nodes -> Enum.uniq(nodes ++ [endpoint]) end))
    else
      {:error, "Enter an HTTP or HTTPS node address without a path or credentials."}
    end
  end

  @impl true
  def init(_) do
    if Application.get_env(:ssi_command, :poll, true), do: send(self(), :poll)
    {:ok, %{instance: {:error, "Checking installation…"}, members: [], task: nil}}
  end

  @impl true
  def handle_call(:snapshot, _, state), do: {:reply, Map.drop(state, [:task]), state}
  @impl true
  def handle_info(:poll, state) do
    config = Store.get()

    task =
      Task.Supervisor.async_nolink(ElixirSSI.Command.Tasks, fn ->
        host = Application.get_env(:ssi_command, :guest_host, "127.0.0.1")
        local = for i <- 1..config["nodes"], do: {"http://#{host}:#{8180 + i}", "Emulated"}
        physical = Enum.map(config["physical"], &{&1, "Physical Pi"})

        members =
          Task.async_stream(
            local ++ physical,
            fn {endpoint, kind} ->
              %{endpoint: endpoint, kind: kind, result: fetch(endpoint)}
            end,
            timeout: 6000,
            on_timeout: :kill_task,
            max_concurrency: 8
          )
          |> Enum.flat_map(fn
            {:ok, member} -> [member]
            _ -> []
          end)

        %{instance: Instances.status(), members: members}
      end)

    {:noreply, %{state | task: task.ref}}
  end

  def handle_info({ref, result}, %{task: ref} = state) do
    Process.demonitor(ref, [:flush])
    Phoenix.PubSub.broadcast(ElixirSSI.Command.PubSub, "command", :cluster_changed)
    Process.send_after(self(), :poll, 3000)
    {:noreply, Map.merge(state, Map.put(result, :task, nil))}
  end

  def handle_info({:DOWN, ref, :process, _, _}, %{task: ref} = state) do
    Process.send_after(self(), :poll, 3000)
    {:noreply, %{state | task: nil}}
  end

  def fetch(endpoint) do
    options = [
      timeout: 3500,
      connect_timeout: 2000,
      autoredirect: false,
      ssl: [
        verify: :verify_peer,
        cacerts: :public_key.cacerts_get(),
        customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
      ]
    ]

    case :httpc.request(:get, {String.to_charlist(endpoint <> "/api/status"), []}, options,
           body_format: :binary
         ) do
      {:ok, {{_, 200, _}, _, body}} ->
        case Jason.decode(body) do
          {:ok, %{"schema" => "elixirssi-status/1", "system" => system} = snapshot}
          when is_map(system) ->
            {:ok, snapshot}

          _ ->
            {:error, "Not an ElixirSSI status endpoint"}
        end

      {:ok, {{_, code, _}, _, _}} ->
        {:error, "HTTP #{code}"}

      {:error, _} ->
        {:error, "Not responding — stopped, booting, unreachable or TLS not trusted"}
    end
  end
end
