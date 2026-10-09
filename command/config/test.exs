import Config
config :ssi_command, poll: false
config :ssi_command, desktop_port: 0

config :ssi_command,
  data_dir: Path.join(System.tmp_dir!(), "ssi-command-tests-#{System.pid()}"),
  password: "test-command-password"

config :ssi_command, ElixirSSI.CommandWeb.Endpoint,
  server: false,
  secret_key_base: String.duplicate("test-key", 8),
  url: [host: "localhost", port: 4000]

config :logger, level: :warning
