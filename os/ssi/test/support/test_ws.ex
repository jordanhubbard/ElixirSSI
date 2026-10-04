defmodule SSI.TestWS do
  @moduledoc """
  A minimal HTTP and WebSocket client for the status endpoint tests, over
  `:gen_tcp` or `:ssl`. A connection is `{transport, socket}`.
  """

  def connect(port, tls \\ nil)

  def connect(port, nil) do
    {:ok, s} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false, packet: :raw])
    {:gen_tcp, s}
  end

  def connect(port, tls_opts) do
    {:ok, s} = :ssl.connect(~c"127.0.0.1", port, [:binary, active: false, packet: :raw] ++ tls_opts, 5_000)
    {:ssl, s}
  end

  def send_data({mod, s}, data), do: mod.send(s, data)
  def recv({mod, s}), do: mod.recv(s, 0, 5_000)

  @doc "One request; `{status, headers, body}`."
  def http(conn, request) do
    :ok = send_data(conn, request)
    data = recv_all(conn, "")
    [head, body] = String.split(data, "\r\n\r\n", parts: 2)
    [status_line | lines] = String.split(head, "\r\n")
    [_, code | _] = String.split(status_line, " ")

    headers =
      Map.new(lines, fn l ->
        [k, v] = String.split(l, ": ", parts: 2)
        {String.downcase(k), v}
      end)

    {String.to_integer(code), headers, body}
  end

  defp recv_all(conn, acc) do
    case recv(conn) do
      {:ok, data} -> recv_all(conn, acc <> data)
      {:error, :closed} -> acc
    end
  end

  @doc "Upgrade to a WebSocket; returns `{head, rest}`."
  def upgrade(conn, key \\ "dGhlIHNhbXBsZSBub25jZQ==") do
    :ok =
      send_data(conn, [
        "GET /api/stream HTTP/1.1\r\nhost: x\r\nupgrade: websocket\r\nconnection: Upgrade\r\n",
        "sec-websocket-key: #{key}\r\nsec-websocket-version: 13\r\n\r\n"
      ])

    recv_head(conn, "")
  end

  def recv_head(conn, acc) do
    case String.split(acc, "\r\n\r\n", parts: 2) do
      [head, rest] ->
        {head, rest}

      _ ->
        {:ok, data} = recv(conn)
        recv_head(conn, acc <> data)
    end
  end

  def recv_frame(conn, buf) do
    case unframe(buf) do
      {op, payload, rest} ->
        {{op, payload}, rest}

      :more ->
        {:ok, data} = recv(conn)
        recv_frame(conn, buf <> data)
    end
  end

  def recv_frame_until(conn, buf, pred) do
    {frame, rest} = recv_frame(conn, buf)
    if pred.(frame), do: {frame, rest}, else: recv_frame_until(conn, rest, pred)
  end

  def recv_json(conn, buf) do
    {{0x1, text}, rest} = recv_frame(conn, buf)
    {JSON.decode!(text), rest}
  end

  def recv_until(conn, buf, pred) do
    {msg, rest} = recv_json(conn, buf)
    if pred.(msg), do: {msg, rest}, else: recv_until(conn, rest, pred)
  end

  def send_text(conn, text), do: :ok = send_data(conn, masked(0x1, text))

  # Server frames are unmasked.
  def unframe(<<1::1, 0::3, op::4, 0::1, 127::7, len::64, payload::binary-size(len), rest::binary>>), do: {op, payload, rest}
  def unframe(<<1::1, 0::3, op::4, 0::1, 126::7, len::16, payload::binary-size(len), rest::binary>>), do: {op, payload, rest}
  def unframe(<<1::1, 0::3, op::4, 0::1, len::7, payload::binary-size(len), rest::binary>>) when len < 126, do: {op, payload, rest}
  def unframe(_), do: :more

  # Client frames are masked.
  def masked(op, payload) do
    mask = :crypto.strong_rand_bytes(4)
    <<a, b, c, d>> = mask
    m = {a, b, c, d}
    body = for {byte, i} <- Enum.with_index(:binary.bin_to_list(payload)), into: <<>>, do: <<Bitwise.bxor(byte, elem(m, rem(i, 4)))>>
    len = byte_size(payload)
    head = if len < 126, do: <<1::1, 0::3, op::4, 1::1, len::7>>, else: <<1::1, 0::3, op::4, 1::1, 126::7, len::16>>
    [head, mask, body]
  end

  def wait_port(server, kind \\ :plain, tries \\ 50) do
    case SSI.Web.listening_port(server, kind) do
      nil when tries > 0 ->
        Process.sleep(20)
        wait_port(server, kind, tries - 1)

      port ->
        port
    end
  end
end
