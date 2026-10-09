defmodule ElixirSSI.Command.Operations do
  @moduledoc "Serialized, supervised operations with durable outcomes and reconnectable progress."
  use GenServer
  alias ElixirSSI.Command.Store
  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  def submit(label, fun), do: GenServer.call(__MODULE__, {:submit, label, fun})

  @impl true
  def init(_) do
    Store.update(fn state ->
      Map.update!(state, "operations", fn operations ->
        Enum.map(operations, fn op ->
          if op["status"] == "running",
            do:
              Map.merge(op, %{
                "status" => "interrupted",
                "result" => "Command node restarted; inspect target state before retrying."
              }),
            else: op
        end)
      end)
    end)

    {:ok, nil}
  end

  @impl true
  def handle_call({:submit, label, fun}, _, nil) do
    id = Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)

    op = %{
      "id" => id,
      "label" => label,
      "status" => "running",
      "started_at" => DateTime.to_iso8601(DateTime.utc_now()),
      "result" => ""
    }

    Store.update(&Map.update!(&1, "operations", fn ops -> Enum.take([op | ops], 100) end))
    task = Task.Supervisor.async_nolink(ElixirSSI.Command.Tasks, fun)
    {:reply, {:ok, id}, {task.ref, id}}
  end

  def handle_call({:submit, _, _}, _, state),
    do: {:reply, {:error, "An operation is already running."}, state}

  @impl true
  def handle_info({ref, result}, {ref, id}) do
    Process.demonitor(ref, [:flush])
    finish(id, result)
    {:noreply, nil}
  end

  def handle_info({:DOWN, ref, :process, _, _reason}, {ref, id}) do
    finish(
      id,
      {:error, "Operation worker stopped unexpectedly. Inspect target state before retrying."}
    )

    {:noreply, nil}
  end

  defp finish(id, result) do
    {status, message} =
      case result do
        {:ok, text} -> {"succeeded", text}
        {:error, text} -> {"failed", text}
        _ -> {"failed", "Operation returned an invalid result."}
      end

    Store.update(fn state ->
      Map.update!(state, "operations", fn ops ->
        Enum.map(ops, fn op ->
          if op["id"] == id,
            do: Map.merge(op, %{"status" => status, "result" => message}),
            else: op
        end)
      end)
    end)
  end
end
