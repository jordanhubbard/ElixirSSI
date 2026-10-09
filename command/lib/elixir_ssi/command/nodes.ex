defmodule ElixirSSI.Command.Nodes do
  @moduledoc "Named operator actions executed through a verified guest SSH connection."
  alias ElixirSSI.Command.Remote

  def inspect_node(target, "processes") do
    Remote.evaluate(target, """
    Process.list()
    |> Enum.flat_map(fn pid ->
      case Process.info(pid, [:registered_name, :memory, :message_queue_len, :current_function]) do
        nil -> []
        info -> [Map.new([{:pid, pid} | info])]
      end
    end)
    |> Enum.sort_by(& &1.memory, :desc)
    |> Enum.take(50)
    |> IO.inspect(limit: :infinity)
    """)
  end

  def inspect_node(target, "logs"),
    do:
      Remote.evaluate(
        target,
        "SSI.Sys.dmesg() |> IO.inspect(limit: :infinity, printable_limit: 200_000)"
      )

  def inspect_node(target, "services"),
    do: Remote.evaluate(target, "SSI.Service.list() |> IO.inspect(limit: :infinity)")

  def move_service(target, label, destination) do
    Remote.evaluate(target, """
    matches = Enum.filter(SSI.Service.list(), &(SSI.Status.label(&1.name) == #{inspect(label)}))
    service = case matches do [one] -> one; _ -> raise "Service is absent or ambiguous; refresh the cluster view" end
    member = Enum.find(SSI.Cluster.members(), &(Atom.to_string(&1) == #{inspect(destination)}))
    unless member, do: raise "Destination is no longer a connected member"
    case SSI.Service.move(service.name, member) do
      :ok -> %{service: service.name, destination: member, result: :migration_requested}
      error -> raise inspect(error)
    end
    """)
  end
end
