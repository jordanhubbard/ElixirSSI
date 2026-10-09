import Config

unless config_env() == :test do
  data = System.get_env("SSI_COMMAND_DATA", Path.expand("data"))
  File.mkdir_p!(data)
  File.chmod!(data, 0o700)
  secret_file = Path.join(data, "session-secret")

  unless File.exists?(secret_file) do
    File.write!(secret_file, Base.encode64(:crypto.strong_rand_bytes(64)), [:exclusive])
    File.chmod!(secret_file, 0o600)
  end

  port = String.to_integer(System.get_env("PORT", "4000"))
  host = System.get_env("SSI_COMMAND_HOST", "localhost")
  bind = if System.get_env("SSI_COMMAND_BIND") == "all", do: {0, 0, 0, 0}, else: {127, 0, 0, 1}
  config :ssi_command, data_dir: data

  config :ssi_command,
    desktop_bind: bind,
    desktop_port: String.to_integer(System.get_env("SSI_DESKTOP_PORT", "4010"))

  config :ssi_command, data_host_dir: System.get_env("SSI_COMMAND_DATA_HOST")
  config :ssi_command, guest_host: System.get_env("SSI_GUEST_HOST", "127.0.0.1")

  config :ssi_command,
    installation_dir: System.get_env("SSI_INSTALLATION"),
    installation_host_dir: System.get_env("SSI_INSTALLATION_HOST")

  config :ssi_command, ElixirSSI.CommandWeb.Endpoint,
    server: true,
    http: [ip: bind, port: port],
    url: [host: host, port: port],
    check_origin: ["http://#{host}:#{port}", "http://127.0.0.1:#{port}"],
    secret_key_base: File.read!(secret_file)
end
