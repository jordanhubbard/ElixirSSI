import Config

config :ssi_command, ElixirSSI.CommandWeb.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  render_errors: [formats: [html: ElixirSSI.CommandWeb.ErrorHTML], layout: false],
  pubsub_server: ElixirSSI.Command.PubSub,
  live_view: [signing_salt: "ssi-command-live"]

config :phoenix, :json_library, Jason
config :phoenix, :filter_parameters, ["password", "ticket", "_csrf_token", "source", "expression"]
config :logger, :level, :info
import_config "#{config_env()}.exs"
