defmodule SSI.Net.DHCP do
  @moduledoc """
  DHCPv4 client (RFC 2131) written against a plain UDP socket.

  The socket is bound to the interface with `SO_BINDTODEVICE`, so broadcasts
  leave through the right port before the interface has an address. The
  BROADCAST flag asks servers to broadcast their replies, which the kernel
  delivers to a socket bound to 0.0.0.0:68 even while the interface is
  unnumbered.

  `acquire/2` performs DISCOVER → OFFER → REQUEST → ACK and returns a lease.
  `SSI.Net` applies it and calls `renew/2` at T1.
  """
  import Bitwise

  @client_port 68
  @server_port 67
  @magic <<99, 130, 83, 99>>
  @types %{1 => :discover, 2 => :offer, 3 => :request, 4 => :decline, 5 => :ack, 6 => :nak, 7 => :release}
  @codes Map.new(@types, fn {k, v} -> {v, k} end)

  defstruct [:ip, :prefix, :router, :dns, :server, :lease, :xid]

  # -- client -----------------------------------------------------------------

  def acquire(ifname, opts \\ []) do
    mac = Keyword.fetch!(opts, :mac)
    hostname = Keyword.get(opts, :hostname, "ssi")
    attempts = Keyword.get(opts, :attempts, 3)
    timeout = Keyword.get(opts, :timeout, 2_000)

    with {:ok, sock} <- open(ifname) do
      try do
        Enum.reduce_while(1..attempts, {:error, :timeout}, fn _, acc ->
          xid = :rand.uniform(0xFFFFFFFF)

          with :ok <- broadcast(sock, encode(:discover, xid, mac, hostname: hostname)),
               {:ok, offer} <- await(sock, xid, [:offer], timeout),
               req = encode(:request, xid, mac, hostname: hostname, requested: offer.ip, server: offer.server),
               :ok <- broadcast(sock, req),
               {:ok, %{type: :ack} = ack} <- await(sock, xid, [:ack, :nak], timeout) do
            {:halt, {:ok, to_lease(ack, xid)}}
          else
            {:ok, %{type: :nak}} -> {:cont, {:error, :nak}}
            _ -> {:cont, acc}
          end
        end)
      after
        :gen_udp.close(sock)
      end
    end
  end

  @doc "Renew an existing lease (REQUEST with ciaddr). Returns a refreshed lease."
  def renew(ifname, %__MODULE__{} = lease, opts) do
    mac = Keyword.fetch!(opts, :mac)

    with {:ok, sock} <- open(ifname) do
      try do
        xid = :rand.uniform(0xFFFFFFFF)
        :ok = broadcast(sock, encode(:request, xid, mac, ciaddr: lease.ip, hostname: opts[:hostname]))

        case await(sock, xid, [:ack, :nak], 2_000) do
          {:ok, %{type: :ack} = ack} -> {:ok, to_lease(ack, xid)}
          {:ok, %{type: :nak}} -> {:error, :nak}
          error -> error
        end
      after
        :gen_udp.close(sock)
      end
    end
  end

  defp open(ifname) do
    :gen_udp.open(@client_port, [
      :binary,
      active: true,
      broadcast: true,
      reuseaddr: true,
      bind_to_device: ifname
    ])
  end

  defp broadcast(sock, packet), do: :gen_udp.send(sock, {255, 255, 255, 255}, @server_port, packet)

  defp await(sock, xid, types, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout

    receive do
      {:udp, ^sock, _ip, @server_port, packet} ->
        case decode(packet) do
          {:ok, %{xid: ^xid, type: type} = msg} ->
            if type in types, do: {:ok, msg}, else: await(sock, xid, types, remaining(deadline))

          _ ->
            await(sock, xid, types, remaining(deadline))
        end
    after
      timeout -> {:error, :timeout}
    end
  end

  defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)

  defp to_lease(msg, xid) do
    %__MODULE__{
      ip: msg.ip,
      prefix: if(msg.options[1], do: SSI.Net.Addr.prefix(msg.options[1]), else: 24),
      router: msg.options[3],
      dns: msg.options[6] || [],
      server: msg.options[54] || msg.server,
      lease: msg.options[51] || 3600,
      xid: xid
    }
  end

  # -- codec ------------------------------------------------------------------

  @doc "Encode a client message."
  def encode(type, xid, <<_::binary-size(6)>> = mac, opts \\ []) do
    ciaddr = Keyword.get(opts, :ciaddr, {0, 0, 0, 0})
    flags = if ciaddr == {0, 0, 0, 0}, do: 0x8000, else: 0

    options =
      [
        {53, <<@codes[type]>>},
        {61, <<1>> <> mac},
        opts[:requested] && {50, SSI.Net.Addr.to_bin(opts[:requested])},
        opts[:server] && {54, SSI.Net.Addr.to_bin(opts[:server])},
        opts[:hostname] && {12, opts[:hostname]},
        {55, <<1, 3, 6, 15, 26, 51, 54>>}
      ]
      |> Enum.reject(&(&1 in [nil, false]))
      |> Enum.map(fn {code, value} -> <<code, byte_size(value), value::binary>> end)

    IO.iodata_to_binary([
      <<1, 1, 6, 0, xid::32, 0::16, flags::16>>,
      SSI.Net.Addr.to_bin(ciaddr),
      <<0::32, 0::32, 0::32>>,
      mac,
      <<0::size(10 * 8)>>,
      <<0::size(64 * 8)>>,
      <<0::size(128 * 8)>>,
      @magic,
      options,
      <<255>>
    ])
  end

  @doc "Decode a server message into a map with `:type`, `:xid`, `:ip`, `:server`, `:options`."
  def decode(
        <<2, 1, 6, _hops, xid::32, _secs::16, _flags::16, _ci::32, yi::binary-size(4), si::binary-size(4),
          _gi::32, _chaddr::binary-size(16), _sname::binary-size(64), _file::binary-size(128), @magic,
          rest::binary>>
      ) do
    options = decode_options(rest, %{})

    case Map.fetch(options, 53) do
      {:ok, type} ->
        {:ok, %{type: type, xid: xid, ip: SSI.Net.Addr.from_bin(yi), server: SSI.Net.Addr.from_bin(si), options: options}}

      :error ->
        {:error, :not_dhcp}
    end
  end

  def decode(_), do: {:error, :malformed}

  defp decode_options(<<255, _::binary>>, acc), do: acc
  defp decode_options(<<0, rest::binary>>, acc), do: decode_options(rest, acc)

  defp decode_options(<<code, len, value::binary-size(len), rest::binary>>, acc) do
    decode_options(rest, Map.put(acc, code, option(code, value)))
  end

  defp decode_options(_, acc), do: acc

  defp option(53, <<t>>), do: Map.get(@types, t, t)
  defp option(code, <<a, b, c, d, _::binary>>) when code in [1, 3, 54], do: {a, b, c, d}
  defp option(6, value), do: for(<<a, b, c, d <- value>>, do: {a, b, c, d})
  defp option(51, <<secs::32>>), do: secs
  defp option(26, <<mtu::16>>), do: mtu
  defp option(15, value), do: value
  defp option(_, value), do: value

  @doc false
  def flags_broadcast?(packet), do: (binary_part(packet, 10, 2) |> :binary.decode_unsigned() &&& 0x8000) != 0
end
