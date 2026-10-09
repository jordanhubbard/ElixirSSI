defmodule ElixirSSI.Command.Auth do
  @moduledoc "Command-node authentication is separate from guest credentials."

  def password do
    Application.get_env(:ssi_command, :password) || persistent_password()
  end

  def valid?(input) when is_binary(input) do
    Plug.Crypto.secure_compare(:crypto.hash(:sha256, input), :crypto.hash(:sha256, password()))
  end

  def valid?(_), do: false

  def session_identity, do: :crypto.hash(:sha256, password()) |> Base.encode64()

  @doc "Issue a one-use browser ticket through the trusted local release RPC."
  def ticket do
    token = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    :global.trans({{__MODULE__, :ticket}, self()}, fn ->
      path = Path.join(ElixirSSI.Command.Store.directory(), "browser-ticket.json")

      File.write!(
        path,
        Jason.encode!(%{"digest" => digest(token), "expires" => System.system_time(:second) + 60})
      )

      File.chmod!(path, 0o600)
    end)

    token
  end

  def consume_ticket(token) when is_binary(token) do
    :global.trans({{__MODULE__, :ticket}, self()}, fn ->
      path = Path.join(ElixirSSI.Command.Store.directory(), "browser-ticket.json")

      with {:ok, text} <- File.read(path),
           {:ok, record} <- Jason.decode(text),
           true <- record["expires"] >= System.system_time(:second),
           true <- Plug.Crypto.secure_compare(record["digest"], digest(token)) do
        File.rm!(path)
        true
      else
        _ -> false
      end
    end)
  end

  def consume_ticket(_), do: false
  defp digest(token), do: :crypto.hash(:sha256, token) |> Base.encode64()

  defp persistent_password do
    path = Path.join(ElixirSSI.Command.Store.directory(), "password")

    case File.read(path) do
      {:ok, value} ->
        String.trim(value)

      {:error, :enoent} ->
        value = Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)

        case File.write(path, value <> "\n", [:exclusive]) do
          :ok ->
            File.chmod!(path, 0o600)
            value

          {:error, :eexist} ->
            persistent_password()
        end
    end
  end
end
