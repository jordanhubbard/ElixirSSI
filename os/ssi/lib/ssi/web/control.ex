defmodule SSI.Web.Control do
  @moduledoc """
  Changing the system from the monitor: trusted keys, pairing and signed
  requests.

  Reading the status needs nothing; changing it needs a key the cluster
  trusts. A browser keeps an ECDSA P-256 key pair it cannot export. An
  operator who can already log in issues a one-time pairing code
  (`pair/1`); the monitor proves it knows the code with an HMAC over the
  connection's challenge and its public key, and the key is recorded in the
  replicated store, so every member trusts it.

  Every WebSocket connection gets a fresh challenge. A request is a JSON text
  naming the key, a sequence number and the action, signed over
  `"elixirssi-action/1\\n" <> challenge <> "\\n" <> text`; a member acts only
  if the key is trusted, the signature verifies and the sequence number is
  higher than any used on the connection. Requests are therefore safe over
  plain HTTP: they cannot be forged, altered or replayed.
  """
  require Logger

  @keys :monitor_keys
  @codes :monitor_pairing
  @pair_ttl_ms 600_000

  # -- shell side ------------------------------------------------------------------

  @doc "Issue a one-time pairing code for a browser called `name`, valid for 10 minutes on every member."
  def pair(name) do
    code = :crypto.strong_rand_bytes(10) |> Base.encode32()
    :ok = SSI.Store.put_sync(@codes, code, %{name: to_string(name), expires: now() + @pair_ttl_ms})
    code |> String.graphemes() |> Enum.chunk_every(4) |> Enum.map_join("-", &Enum.join/1)
  end

  @doc "Trusted keys: `[%{id:, name:, added_at:, via:}]`."
  def keys do
    for {id, k} <- SSI.Store.all(@keys), do: %{id: id, name: k.name, added_at: k.added_at, via: k.via}
  end

  @doc "Ids of the trusted keys (published in every snapshot)."
  def key_ids, do: SSI.Store.keys(@keys) |> Enum.sort()

  @doc "Stop trusting a key, by id or name. Returns the ids removed."
  def revoke(id_or_name) do
    gone = for {id, k} <- SSI.Store.all(@keys), id == id_or_name or k.name == id_or_name, do: id
    Enum.each(gone, &SSI.Store.delete(@keys, &1))
    gone
  end

  @doc "Trust `public_key` (raw uncompressed P-256 point) under `name`; returns its id."
  def trust(public_key, name, via \\ "shell") do
    id = key_id(public_key)
    :ok = SSI.Store.put_sync(@keys, id, %{name: name, key: public_key, added_at: now(), via: via})
    id
  end

  @doc "The key id: 16 characters of the unpadded base64url SHA-256 of the raw public key."
  def key_id(public_key), do: :crypto.hash(:sha256, public_key) |> Base.url_encode64(padding: false) |> binary_part(0, 16)

  # -- connection side ---------------------------------------------------------------

  @doc "A fresh challenge for a new connection, base64."
  def challenge, do: :crypto.strong_rand_bytes(32) |> Base.encode64()

  @doc """
  Handle one client message on a connection with `challenge`. `last_seq` is
  the highest sequence number accepted on it. Returns `{reply, last_seq}`;
  the reply is nil for messages that are not requests.
  """
  def handle(text, challenge, last_seq) do
    case JSON.decode(text) do
      {:ok, %{"type" => "pair", "request" => req, "mac" => mac}} when is_binary(req) and is_binary(mac) ->
        with_request(req, last_seq, fn r -> pair_request(r, req, mac, challenge) end)

      {:ok, %{"type" => "action", "request" => req, "sig" => sig}} when is_binary(req) and is_binary(sig) ->
        with_request(req, last_seq, fn r -> action_request(r, req, sig, challenge) end)

      {:ok, %{"type" => type}} when type in ["pair", "action"] ->
        {result(nil, {:error, "malformed request"}), last_seq}

      _ ->
        {nil, last_seq}
    end
  end

  defp with_request(req, last_seq, fun) do
    case JSON.decode(req) do
      {:ok, %{"seq" => seq} = r} when is_integer(seq) ->
        case fun.(r) do
          # Only authenticated requests use up a sequence number.
          {:authenticated, outcome} when seq > last_seq -> {result(seq, outcome), seq}
          {:authenticated, _} -> {result(seq, {:error, "replayed request"}), last_seq}
          {:refused, why} -> {result(seq, {:error, why}), last_seq}
        end

      _ ->
        {result(nil, {:error, "malformed request"}), last_seq}
    end
  end

  defp result(seq, :ok), do: result(seq, {:ok, nil})
  defp result(seq, {:ok, value}), do: %{type: "result", seq: seq, ok: true, value: value}
  defp result(seq, {:error, why}), do: %{type: "result", seq: seq, ok: false, error: why}

  # -- pairing --------------------------------------------------------------------------

  defp pair_request(r, req, mac, challenge) do
    signed = "elixirssi-pair/1\n" <> challenge <> "\n" <> req

    with {:ok, mac} <- Base.decode64(mac),
         {:ok, key} <- decode_key(r["key"]),
         {code, %{name: name}} <-
           Enum.find(SSI.Store.all(@codes), fn {code, c} ->
             c.expires > now() and :crypto.hash_equals(mac, :crypto.mac(:hmac, :sha256, code, signed))
           end) do
      SSI.Store.delete(@codes, code)
      id = trust(key, name, "pairing code")
      Logger.info("monitor: paired key #{id} as #{name}")
      SSI.Status.Journal.control(name, %{action: "pair", by: name, key: id, ok: true})
      {:authenticated, {:ok, %{id: id, name: name}}}
    else
      _ -> {:refused, "pairing refused: wrong or expired code"}
    end
  end

  defp decode_key(text) when is_binary(text) do
    case Base.url_decode64(text, padding: false) do
      {:ok, <<4, _::binary-size(64)>> = key} -> {:ok, key}
      _ -> :error
    end
  end

  defp decode_key(_), do: :error

  # -- actions ------------------------------------------------------------------------------

  defp action_request(r, req, sig, challenge) do
    signed = "elixirssi-action/1\n" <> challenge <> "\n" <> req

    with id when is_binary(id) <- r["key"],
         %{key: key, name: name} <- SSI.Store.get(@keys, id),
         {:ok, sig} <- Base.decode64(sig),
         true <- verify(signed, sig, key) do
      outcome = perform(r)
      target = r["service"] || r["member"]
      detail =
        case outcome do
          {:ok, value} -> %{action: r["action"], by: name, key: id, to: value[:to], ok: true}
          {:error, why} -> %{action: r["action"], by: name, key: id, to: r["to"], ok: false, error: why}
        end

      SSI.Status.Journal.control(to_string(target), detail)
      {:authenticated, outcome}
    else
      _ -> {:refused, "unauthorized"}
    end
  end

  # WebCrypto signs P-256 as r || s (IEEE P1363); :crypto wants DER.
  defp verify(data, <<r::256, s::256>>, key) do
    der = :public_key.der_encode(:"ECDSA-Sig-Value", {:"ECDSA-Sig-Value", r, s})
    :crypto.verify(:ecdsa, :sha256, data, der, [key, :secp256r1])
  end

  defp verify(_, _, _), do: false

  defp perform(%{"action" => "migrate", "service" => label, "to" => to}) when is_binary(label) and is_binary(to) do
    with {:ok, name} <- service(label),
         {:ok, node} <- member(to),
         :ok <- SSI.Service.move(name, node) do
      {:ok, %{service: label, to: SSI.Cluster.hostname(node)}}
    else
      {:error, why} when is_binary(why) -> {:error, why}
      {:error, why} -> {:error, inspect(why)}
    end
  end

  defp perform(%{"action" => how, "member" => target}) when how in ["restart", "poweroff"] and is_binary(target) do
    with {:ok, node} <- member(target) do
      how = String.to_existing_atom(how)

      case :erpc.call(node, SSI.Power, :local, [how], 5_000) do
        :ok -> {:ok, %{member: SSI.Cluster.hostname(node), action: how}}
        {:error, :hosted} -> {:error, "#{target} is a hosted node and cannot #{how}"}
        {:error, why} -> {:error, inspect(why)}
      end
    end
  catch
    _, why -> {:error, "#{target}: #{inspect(why)}"}
  end

  defp perform(_), do: {:error, "unknown action"}

  defp service(label) do
    case Enum.find(SSI.Service.list(), &(SSI.Status.label(&1.name) == label)) do
      nil -> {:error, "no service #{label}"}
      s -> {:ok, s.name}
    end
  end

  defp member(target) do
    {:ok, SSI.Proc.resolve_node(target)}
  rescue
    ArgumentError -> {:error, "no member #{target}"}
  end

  defp now, do: System.os_time(:millisecond)
end
