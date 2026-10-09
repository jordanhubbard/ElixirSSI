defmodule ElixirSSI.Command.Application do
  use Application

  def start(_type, _args) do
    children = [
      {Phoenix.PubSub, name: ElixirSSI.Command.PubSub},
      {Task.Supervisor, name: ElixirSSI.Command.Tasks},
      ElixirSSI.Command.Store,
      ElixirSSI.Command.Desktop,
      ElixirSSI.Command.Operations,
      ElixirSSI.Command.Cluster,
      ElixirSSI.CommandWeb.Endpoint
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: ElixirSSI.Command.Supervisor)
  end

  def config_change(changed, _new, removed) do
    ElixirSSI.CommandWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
