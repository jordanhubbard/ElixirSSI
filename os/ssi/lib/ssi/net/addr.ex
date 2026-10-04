defmodule SSI.Net.Addr do
  @moduledoc "IPv4 address arithmetic and parsing."
  import Bitwise

  def to_int({a, b, c, d}), do: a <<< 24 ||| b <<< 16 ||| c <<< 8 ||| d
  def from_int(n), do: {n >>> 24 &&& 255, n >>> 16 &&& 255, n >>> 8 &&& 255, n &&& 255}

  def netmask(prefix) when prefix in 0..32, do: from_int(bnot(0xFFFFFFFF >>> prefix) &&& 0xFFFFFFFF)
  def netmask_bin(prefix), do: prefix |> netmask() |> to_bin()

  def prefix({_, _, _, _} = mask), do: mask |> to_int() |> Integer.digits(2) |> Enum.count(&(&1 == 1))

  def to_bin({a, b, c, d}), do: <<a, b, c, d>>
  def from_bin(<<a, b, c, d>>), do: {a, b, c, d}

  def to_string({_, _, _, _} = ip), do: ip |> :inet.ntoa() |> List.to_string()

  def parse(text) when is_binary(text) do
    case :inet.parse_ipv4strict_address(String.to_charlist(text)) do
      {:ok, ip} -> {:ok, ip}
      _ -> {:error, :einval}
    end
  end

  @doc "Parse `\"10.0.0.5/24\"` into `{ip, prefix}`."
  def parse_cidr(text) do
    with [ip, len] <- String.split(text, "/"),
         {:ok, ip} <- parse(ip),
         {prefix, ""} when prefix in 0..32 <- Integer.parse(len) do
      {:ok, ip, prefix}
    else
      _ -> {:error, :einval}
    end
  end

  def same_subnet?(a, b, prefix) do
    m = prefix |> netmask() |> to_int()
    (to_int(a) &&& m) == (to_int(b) &&& m)
  end

  @doc """
  Deterministic IPv4 link-local address (RFC 3927 range 169.254.1.0 –
  169.254.254.255) derived from a MAC address, so a node keeps the same
  cluster address across reboots without a DHCP server.
  """
  def link_local(<<_::binary-size(4), x, y>> = mac) when byte_size(mac) == 6 do
    {169, 254, rem(x + :erlang.crc32(mac), 254) + 1, y}
  end
end
