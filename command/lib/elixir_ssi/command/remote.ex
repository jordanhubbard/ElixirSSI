defmodule ElixirSSI.Command.Remote do
  @moduledoc "Authenticated Elixir SSH execution with explicit host fingerprint trust."
  alias ElixirSSI.Command.Store

  def probe(host, port) do
    caller = self()
    ref = make_ref()

    callback = fn _, fingerprint ->
      send(caller, {ref, to_string(fingerprint)})
      false
    end

    connect(host, port, "", callback)

    receive do
      {^ref, fingerprint} -> {:ok, fingerprint}
    after
      100 -> {:error, "Could not read the SSH host identity. Check its address and SSH port."}
    end
  end

  def trust(host, port, fingerprint, password) do
    with true <- is_binary(host) and host != "" and port in 1..65535 and byte_size(password) > 0,
         {:ok, actual} <- probe(host, port),
         true <- actual == fingerprint,
         {:ok, connection} <-
           connect(host, port, password, fn _, seen -> to_string(seen) == fingerprint end) do
      :ssh.close(connection)

      :global.trans({__MODULE__, self()}, fn ->
        credentials =
          credentials()
          |> Map.put(key(host, port), %{"fingerprint" => fingerprint, "password" => password})

        path = Path.join(Store.directory(), "ssh-credentials.json")
        File.write!(path <> ".tmp", Jason.encode!(credentials))
        File.chmod!(path <> ".tmp", 0o600)
        File.rename!(path <> ".tmp", path)
      end)

      {:ok, "SSH identity trusted for #{host}:#{port}."}
    else
      _ ->
        {:error,
         "SSH identity or password verification failed. Check the credentials and inspect the host again."}
    end
  end

  def targets, do: credentials() |> Map.keys() |> Enum.sort()

  def evaluate(target, source) when is_binary(source) and byte_size(source) <= 240_000 do
    with %{"fingerprint" => fingerprint, "password" => password} <- credentials()[target],
         [host, port] <- String.split(target, "|"),
         {port, ""} <- Integer.parse(port),
         {:ok, connection} <-
           connect(host, port, password, fn _, actual -> to_string(actual) == fingerprint end) do
      try do
        with {:ok, channel} <- :ssh_connection.session_channel(connection, 5000),
             :success <-
               :ssh_connection.exec(connection, channel, String.to_charlist(source), 5000) do
          collect(connection, channel, System.monotonic_time(:millisecond) + 35_000, "", nil)
        else
          error -> {:error, "SSH execution request failed: #{inspect(error)}"}
        end
      after
        :ssh.close(connection)
      end
    else
      nil -> {:error, "Trust this node's SSH identity before executing code."}
      _ -> {:error, "SSH authentication or host identity verification failed."}
    end
  end

  def evaluate(_, _),
    do:
      {:error,
       "Remote expressions must be smaller than 240 KB. Deployment transfers larger applications in chunks."}

  defp connect(host, port, password, callback) do
    # No known_hosts file is written: every connection checks the exact stored fingerprint.
    dir = Path.join(Store.directory(), "ssh")
    File.mkdir_p!(dir)

    :ssh.connect(
      String.to_charlist(host),
      port,
      [
        user: ~c"root",
        password: String.to_charlist(password),
        user_interaction: false,
        user_dir: String.to_charlist(dir),
        save_accepted_host: false,
        silently_accept_hosts: {:sha256, callback},
        auth_methods: ~c"password",
        preferred_algorithms: [public_key: [:"ssh-ed25519"]]
      ],
      5000
    )
  end

  defp credentials do
    case File.read(Path.join(Store.directory(), "ssh-credentials.json")) do
      {:ok, text} -> Jason.decode!(text)
      {:error, :enoent} -> %{}
    end
  end

  defp key(host, port), do: "#{host}|#{port}"

  defp collect(connection, channel, deadline, output, status) do
    receive do
      {:ssh_cm, ^connection, {:data, ^channel, _, data}} ->
        if byte_size(output) + byte_size(data) > 262_144,
          do: {:error, "Remote output exceeded 256 KiB."},
          else: collect(connection, channel, deadline, output <> data, status)

      {:ssh_cm, ^connection, {:exit_status, ^channel, code}} ->
        collect(connection, channel, deadline, output, code)

      {:ssh_cm, ^connection, {:eof, ^channel}} ->
        collect(connection, channel, deadline, output, status)

      {:ssh_cm, ^connection, {:closed, ^channel}} ->
        if status == 0, do: {:ok, output}, else: {:error, output}
    after
      max(0, deadline - System.monotonic_time(:millisecond)) ->
        {:error, "Remote evaluation timed out."}
    end
  end
end
