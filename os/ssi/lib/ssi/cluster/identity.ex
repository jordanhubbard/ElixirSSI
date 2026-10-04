defmodule SSI.Cluster.Identity do
  @moduledoc """
  Cluster identity derived from the shared secret.

  All nodes configured with the same `cluster` name and `secret` derive the
  same distribution cookie and the same beacon-signing key, so the operator
  provisions one secret and never handles cookies.
  """

  def cluster, do: SSI.Config.get("cluster")

  def cookie do
    key("cookie") |> Base.encode32(padding: false) |> String.to_atom()
  end

  @doc "HMAC-SHA256 key for discovery beacons."
  def beacon_key, do: key("beacon")

  defp key(purpose) do
    :crypto.mac(:hmac, :sha256, SSI.Config.get("secret"), purpose <> ":" <> cluster())
  end

  def sign(payload), do: payload <> :crypto.mac(:hmac, :sha256, beacon_key(), payload)

  def verify(packet) when byte_size(packet) > 32 do
    size = byte_size(packet) - 32
    <<payload::binary-size(^size), mac::binary-size(32)>> = packet

    if :crypto.hash_equals(mac, :crypto.mac(:hmac, :sha256, beacon_key(), payload)),
      do: {:ok, payload},
      else: {:error, :bad_signature}
  end

  def verify(_), do: {:error, :short}
end
