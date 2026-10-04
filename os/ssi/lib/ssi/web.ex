defmodule SSI.Web do
  @moduledoc """
  The status endpoint every member serves, for the monitor.

      GET /            the monitor page (priv/monitor/index.html)
      GET /api/status  a JSON snapshot (`SSI.Status`)
      GET /api/stream  WebSocket: a `hello` with this connection's challenge,
                       a snapshot with the journal, then a snapshot every
                       second and each journal event as it is recorded; it
                       accepts signed control requests (`SSI.Web.Control`)
      GET /ca.pem      the web CA certificate (`SSI.Web.TLS`)

  HTTP/1.1 and RFC 6455 on `:gen_tcp`, on every address: plain on
  `web.port` (default 80) and TLS on `web.tls_port` (default 443) with a
  certificate from the cluster's web CA; 0 disables either. Responses allow
  any origin, so the monitor works from a local file. Reading needs nothing;
  only a request signed by a paired key changes the system. Each connection
  is its own process; a client that stops reading is dropped after five
  seconds rather than holding a snapshot in memory.
  """
  use GenServer
  require Logger

  @guid "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
  @max_frame 65_536
  @interval 1_000

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc "The port members serve the endpoint on, or nil when it is disabled."
  def port, do: configured("web.port", 80)

  @doc "The port members serve the endpoint on over TLS, or nil when it is disabled."
  def tls_port, do: configured("web.tls_port", 443)

  defp configured(key, default) do
    port = SSI.Config.integer(key, default)
    if port == 0 or not enabled?(), do: nil, else: port
  end

  @doc "The port a running server listens on, `:plain` or `:tls` (tests start them on port 0)."
  def listening_port(server \\ __MODULE__, kind \\ :plain), do: GenServer.call(server, {:port, kind})

  defp enabled?, do: SSI.Sys.target?() or Application.get_env(:ssi, :web, false)

  # -- server -----------------------------------------------------------------

  @impl true
  def init(opts) do
    ports = %{plain: Keyword.get_lazy(opts, :port, &port/0), tls: Keyword.get_lazy(opts, :tls_port, &tls_port/0)}

    if ports.plain == nil and ports.tls == nil do
      :ignore
    else
      for {kind, port} <- ports, port != nil, do: send(self(), {:listen, kind, port})
      {:ok, %{plain: nil, tls: nil}}
    end
  end

  @impl true
  def handle_call({:port, kind}, _from, state), do: {:reply, state[kind], state}

  @impl true
  def handle_info({:listen, kind, port}, state) do
    # A TLS connection reads HTTP only after the handshake (see serve/2).
    packet = if kind == :tls, do: :raw, else: :http_bin
    opts = [:binary, packet: packet, active: false, reuseaddr: true, backlog: 128, send_timeout: 5_000, send_timeout_close: true]

    case :gen_tcp.listen(port, opts) do
      {:ok, listen} ->
        {:ok, actual} = :inet.port(listen)
        Logger.info("web: status endpoint on port #{actual}#{if kind == :tls, do: " (TLS)"}")
        spawn_link(fn -> accept(listen, kind) end)
        {:noreply, Map.put(state, kind, actual)}

      {:error, reason} ->
        Logger.error("web: cannot listen on #{port}: #{inspect(reason)}")
        Process.send_after(self(), {:listen, kind, port}, 5_000)
        {:noreply, state}
    end
  end

  defp accept(listen, kind) do
    case :gen_tcp.accept(listen) do
      {:ok, sock} ->
        {:ok, pid} =
          Task.Supervisor.start_child(SSI.TaskSup, fn ->
            receive do
              :go -> serve(sock, kind)
            end
          end)

        case :gen_tcp.controlling_process(sock, pid) do
          :ok -> send(pid, :go)
          _ -> :gen_tcp.close(sock)
        end

        accept(listen, kind)

      {:error, :closed} ->
        :ok

      {:error, _} ->
        Process.sleep(100)
        accept(listen, kind)
    end
  end

  # -- HTTP -------------------------------------------------------------------

  # A connection is `{transport, socket}`, the transport `:gen_tcp` or `:ssl`.
  defp serve(sock, :plain), do: request({:gen_tcp, sock})

  defp serve(sock, :tls) do
    case :ssl.handshake(sock, SSI.Web.TLS.server_opts(), 10_000) do
      {:ok, tls} ->
        :ok = :ssl.setopts(tls, [:binary, packet: :http_bin, active: false])
        request({:ssl, tls})

      {:error, _} ->
        :gen_tcp.close(sock)
    end
  end

  defp request(conn) do
    with {:ok, {:http_request, method, {:abs_path, target}, _vsn}} <- recv(conn, 10_000),
         {:ok, headers} <- headers(conn, %{}) do
      path = target |> String.split("?") |> hd()
      route(conn, method, path, headers)
    else
      _ -> close(conn)
    end
  end

  defp recv({mod, sock}, timeout), do: mod.recv(sock, 0, timeout)
  defp send_data({mod, sock}, data), do: mod.send(sock, data)
  defp close({mod, sock}), do: mod.close(sock)
  defp setopts({:gen_tcp, sock}, opts), do: :inet.setopts(sock, opts)
  defp setopts({:ssl, sock}, opts), do: :ssl.setopts(sock, opts)

  defp headers(conn, acc) when map_size(acc) < 64 do
    case recv(conn, 10_000) do
      {:ok, {:http_header, _, name, _, value}} -> headers(conn, Map.put(acc, name |> to_string() |> String.downcase(), value))
      {:ok, :http_eoh} -> {:ok, acc}
      _ -> :error
    end
  end

  defp headers(_conn, _acc), do: :error

  defp route(conn, :OPTIONS, _path, headers) do
    pna = if headers["access-control-request-private-network"], do: [{"access-control-allow-private-network", "true"}], else: []

    respond(conn, 204, [
      {"access-control-allow-methods", "GET, OPTIONS"},
      {"access-control-allow-headers", headers["access-control-request-headers"] || "*"},
      {"access-control-max-age", "600"} | pna
    ], "")
  end

  defp route(conn, :GET, "/api/stream", headers) do
    if String.downcase(headers["upgrade"] || "") == "websocket" and headers["sec-websocket-key"] do
      websocket(conn, headers["sec-websocket-key"])
    else
      respond(conn, 426, [{"upgrade", "websocket"}], "WebSocket required\n")
    end
  end

  defp route(conn, :GET, "/api/status", _headers) do
    respond(conn, 200, [{"content-type", "application/json"}], SSI.Status.json())
  end

  defp route(conn, :GET, "/ca.pem", _headers) do
    file = "elixirssi-#{SSI.Cluster.Identity.cluster()}-web-ca.pem"
    headers = [{"content-type", "application/x-pem-file"}, {"content-disposition", ~s(attachment; filename="#{file}")}]
    respond(conn, 200, headers, SSI.Web.TLS.ca_pem())
  end

  defp route(conn, :GET, path, _headers) when path in ["/", "/index.html"] do
    case File.read(page()) do
      {:ok, html} -> respond(conn, 200, [{"content-type", "text/html; charset=utf-8"}], html)
      _ -> respond(conn, 404, [], "monitor page not installed\n")
    end
  end

  defp route(conn, :GET, _path, _headers), do: respond(conn, 404, [], "not found\n")
  defp route(conn, _method, _path, _headers), do: respond(conn, 405, [{"allow", "GET, OPTIONS"}], "not allowed\n")

  @doc "Path of the monitor page in this release."
  def page, do: Path.join(:code.priv_dir(:ssi), "monitor/index.html")

  defp respond(conn, status, headers, body) do
    head =
      [
        "HTTP/1.1 #{status} #{reason(status)}\r\n",
        for({k, v} <- base_headers() ++ headers, do: "#{k}: #{v}\r\n"),
        "content-length: #{byte_size(body)}\r\n\r\n"
      ]

    send_data(conn, [head, body])
    close(conn)
  end

  defp base_headers do
    [
      {"server", "ElixirSSI"},
      {"connection", "close"},
      {"cache-control", "no-store"},
      {"access-control-allow-origin", "*"},
      {"x-content-type-options", "nosniff"}
    ]
  end

  defp reason(200), do: "OK"
  defp reason(204), do: "No Content"
  defp reason(404), do: "Not Found"
  defp reason(405), do: "Method Not Allowed"
  defp reason(426), do: "Upgrade Required"

  # -- WebSocket ----------------------------------------------------------------

  defp websocket(conn, key) do
    accept = :crypto.hash(:sha, key <> @guid) |> Base.encode64()

    :ok =
      send_data(conn, [
        "HTTP/1.1 101 Switching Protocols\r\n",
        "upgrade: websocket\r\nconnection: Upgrade\r\n",
        "sec-websocket-accept: #{accept}\r\n\r\n"
      ])

    :ok = setopts(conn, packet: :raw, active: :once)
    SSI.Events.subscribe(SSI.Status.Journal.topic())
    # Control requests on this connection are signed over its challenge.
    ws = %{conn: conn, buf: <<>>, challenge: SSI.Web.Control.challenge(), seq: 0}
    push(conn, %{type: "hello", protocol: "elixirssi-control/1", challenge: ws.challenge, tls: elem(conn, 0) == :ssl})
    push(conn, %{type: "snapshot", status: SSI.Status.snapshot()})
    Process.send_after(self(), :snapshot, @interval)
    ws_loop(ws)
  end

  defp ws_loop(%{conn: {_, sock} = conn} = ws) do
    receive do
      :snapshot ->
        push(conn, %{type: "snapshot", status: SSI.Status.snapshot(journal: false)})
        Process.send_after(self(), :snapshot, @interval)
        ws_loop(ws)

      {:ssi_journal, event} ->
        push(conn, %{type: "event", event: event})
        ws_loop(ws)

      {transport, ^sock, data} when transport in [:tcp, :ssl] ->
        setopts(conn, active: :once)
        frames(%{ws | buf: ws.buf <> data})

      {closed, ^sock} when closed in [:tcp_closed, :ssl_closed] ->
        :ok

      {error, ^sock, _} when error in [:tcp_error, :ssl_error] ->
        :ok
    end
  end

  defp frames(%{conn: conn} = ws) do
    case decode(ws.buf) do
      {:frame, 0x8, _payload, _rest} ->
        send_data(conn, <<0x88, 2, 1000::16>>)
        close(conn)

      {:frame, 0x9, payload, rest} ->
        send_frame(conn, 0xA, payload)
        frames(%{ws | buf: rest})

      {:frame, 0x1, text, rest} ->
        {reply, seq} = SSI.Web.Control.handle(text, ws.challenge, ws.seq)
        if reply, do: push(conn, reply)
        frames(%{ws | buf: rest, seq: seq})

      {:frame, _opcode, _payload, rest} ->
        frames(%{ws | buf: rest})

      :more ->
        ws_loop(ws)

      :error ->
        send_data(conn, <<0x88, 2, 1009::16>>)
        close(conn)
    end
  end

  # Client frames are always masked (RFC 6455 5.3).
  @doc false
  def decode(<<_fin::1, _rsv::3, op::4, 1::1, 127::7, len::64, rest::binary>>), do: unmask(op, len, rest)
  def decode(<<_fin::1, _rsv::3, op::4, 1::1, 126::7, len::16, rest::binary>>), do: unmask(op, len, rest)
  def decode(<<_fin::1, _rsv::3, op::4, 1::1, len::7, rest::binary>>) when len < 126, do: unmask(op, len, rest)
  def decode(<<_::8, 0::1, _::7, _::binary>>), do: :error
  def decode(_), do: :more

  defp unmask(_op, len, _rest) when len > @max_frame, do: :error

  defp unmask(op, len, rest) do
    case rest do
      <<mask::binary-4, payload::binary-size(^len), rest::binary>> -> {:frame, op, xor(payload, mask), rest}
      _ -> :more
    end
  end

  defp xor(payload, <<a, b, c, d>>) do
    for {byte, i} <- Enum.with_index(:binary.bin_to_list(payload)), into: <<>> do
      <<Bitwise.bxor(byte, elem({a, b, c, d}, rem(i, 4)))>>
    end
  end

  defp push(conn, message) do
    case send_frame(conn, 0x1, JSON.encode!(message)) do
      :ok -> :ok
      {:error, _} -> exit(:normal)
    end
  end

  @doc false
  def frame(op, payload) do
    len = byte_size(payload)

    header =
      cond do
        len < 126 -> <<1::1, 0::3, op::4, 0::1, len::7>>
        len < 65_536 -> <<1::1, 0::3, op::4, 0::1, 126::7, len::16>>
        true -> <<1::1, 0::3, op::4, 0::1, 127::7, len::64>>
      end

    [header, payload]
  end

  defp send_frame(conn, op, payload), do: send_data(conn, frame(op, payload))
end
