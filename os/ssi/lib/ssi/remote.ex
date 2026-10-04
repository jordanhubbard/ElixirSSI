defmodule SSI.Remote do
  @moduledoc """
  Client for the RemoteOS protocol v2 (see RemoteOS-SDL `PROTOCOL.md`).

  The guest owns the scene; the host service owns the window, input devices
  and audio. Every envelope is a 4-byte big-endian length followed by UTF-8
  JSON; `params.payload_len` announces a raw binary trailer. Requests with a
  positive id get a response; id 0 is an ordered one-way notification.

  The client is a plain struct used by one owning process (the desktop), so
  there is no extra process hop on the frame path.
  """

  defstruct [:sock, :features, :limits, next: 1]

  @connect_timeout 3_000
  @reply_timeout 10_000

  @doc "Connect and negotiate. `endpoint` is `\"host:port\"`."
  def connect(endpoint, client \\ "elixirssi/#{Application.spec(:ssi, :vsn)}") do
    with {:ok, host, port} <- parse(endpoint),
         {:ok, sock} <-
           :gen_tcp.connect(host, port, [:binary, active: false, packet: :raw, nodelay: true, sndbuf: 1_048_576], @connect_timeout) do
      conn = %__MODULE__{sock: sock}

      case call(conn, "hello", %{protocol: 2, client: client}) do
        {:ok, result, conn} -> {:ok, %{conn | features: result["features"] || [], limits: result["limits"] || %{}}}
        {:error, reason, _} -> close(conn) && {:error, reason}
      end
    end
  end


  def parse(endpoint) do
    case String.split(to_string(endpoint), ":") do
      [host, port] -> {:ok, String.to_charlist(host), String.to_integer(port)}
      _ -> {:error, :bad_endpoint}
    end
  end

  def close(%__MODULE__{sock: sock}), do: :gen_tcp.close(sock) == :ok

  @doc "Request/response. Returns `{:ok, result, conn}` or `{:error, error, conn}`."
  def call(conn, op, params \\ %{}, payload \\ nil) do
    id = conn.next
    conn = %{conn | next: id + 1}

    with :ok <- send_envelope(conn, id, op, params, payload),
         {:ok, reply} <- receive_envelope(conn) do
      case reply do
        %{"id" => ^id, "ok" => true} -> {:ok, reply["result"] || %{}, conn}
        %{"id" => ^id, "error" => error} -> {:error, error, conn}
        other -> {:error, {:unexpected, other}, conn}
      end
    else
      {:error, reason} -> {:error, reason, conn}
    end
  end

  @doc "Ordered one-way notification (no response)."
  def notify(conn, op, params \\ %{}), do: send_envelope(conn, 0, op, params, nil)

  @doc "Send drawing operations as `render.batch` requests within the service limit."
  def batch(conn, []), do: {:ok, conn}

  def batch(conn, ops) do
    limit = conn.limits["batch_ops"] || 1024

    ops
    |> Enum.chunk_every(limit)
    |> Enum.reduce_while({:ok, conn}, fn chunk, {:ok, c} ->
      case call(c, "render.batch", %{ops: chunk}) do
        {:ok, _, c} -> {:cont, {:ok, c}}
        {:error, e, c} -> {:halt, {:error, e, c}}
      end
    end)
  end

  defp send_envelope(conn, id, op, params, payload) do
    params = if payload, do: Map.put(params, :payload_len, byte_size(payload)), else: params
    json = JSON.encode!(%{v: 2, id: id, op: op, params: params})
    :gen_tcp.send(conn.sock, [<<byte_size(json)::32>>, json | if(payload, do: [payload], else: [])])
  end

  defp receive_envelope(conn) do
    with {:ok, <<len::32>>} <- :gen_tcp.recv(conn.sock, 4, @reply_timeout),
         {:ok, json} <- :gen_tcp.recv(conn.sock, len, @reply_timeout) do
      {:ok, JSON.decode!(json)}
    end
  end

  # -- drawing operation builders (for render.batch) --------------------------

  @doc "ARGB pixel value for an 0xRRGGBB colour."
  def px(rgb), do: 0xFF000000 + rgb

  def fill(h, x, y, w, hh, rgb),
    do: %{op: "surface.fill_rect", params: %{handle: h, rect: %{x: x, y: y, w: w, h: hh}, rgb: px(rgb)}}

  def line(h, x0, y0, x1, y1, rgb),
    do: %{op: "surface.line", params: %{handle: h, x0: x0, y0: y0, x1: x1, y1: y1, rgb: px(rgb)}}

  def text(h, x, y, text, fg, bg \\ nil) do
    params = %{handle: h, x: x, y: y, text: sanitize(text), fg: px(fg)}
    %{op: "text.draw", params: if(bg, do: Map.put(params, :bg, px(bg)), else: params)}
  end

  def blit(src, dst, x, y, w, h),
    do: %{op: "surface.blit", params: %{src: src, dst: dst, dst_rect: %{x: x, y: y, w: w, h: h}}}

  def rect(h, x, y, w, hh, rgb) do
    [line(h, x, y, x + w - 1, y, rgb), line(h, x, y + hh - 1, x + w - 1, y + hh - 1, rgb),
     line(h, x, y, x, y + hh - 1, rgb), line(h, x + w - 1, y, x + w - 1, y + hh - 1, rgb)]
  end

  # The service font covers printable ASCII.
  defp sanitize(text) do
    for <<c::utf8 <- to_string(text)>>, into: "", do: if(c in 32..126 or c == ?\n, do: <<c>>, else: "?")
  end
end
