import Config

config :logger, :default_formatter,
  format: "$time [$level] $metadata$message\n",
  metadata: [:node]

config :ssi, mode: :hosted

if config_env() == :prod do
  # The production release only ever runs as PID 1 on ElixirSSI hardware.
  config :ssi, mode: :target
  config :logger, level: :info
end

if config_env() == :test do
  config :logger, level: :warning
  config :ssi, autostart_services: false
end
