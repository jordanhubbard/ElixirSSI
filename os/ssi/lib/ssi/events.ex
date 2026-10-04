defmodule SSI.Events do
  @moduledoc """
  Node-local publish/subscribe used by system services.

  Topics: `:membership` (`{:ssi_membership, :up | :down, node}`), and
  `{:store, table}` (`{:ssi_store, table, key, value | :deleted}`).
  Cluster-wide fan-out is done by the publishers (the store and membership
  monitor each run on every node), so subscribers only ever listen locally.
  """

  def child_spec(_), do: Registry.child_spec(keys: :duplicate, name: __MODULE__)

  def subscribe(topic), do: Registry.register(__MODULE__, topic, nil)
  def unsubscribe(topic), do: Registry.unregister(__MODULE__, topic)

  def publish(topic, message) do
    Registry.dispatch(__MODULE__, topic, fn entries ->
      for {pid, _} <- entries, do: send(pid, message)
    end)
  end
end
