defmodule SSI.RemoteTest do
  use ExUnit.Case, async: true
  alias SSI.Remote

  # A minimal RemoteOS-v2 service: answers every request, records envelopes
  # and trailers, and returns one queued mouse event on the first commit.
  defp fake_service(test_pid, batch_ops \\ 2) do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, packet: :raw, reuseaddr: true])
    {:ok, port} = :inet.port(listen)

    spawn_link(fn ->
      {:ok, sock} = :gen_tcp.accept(listen)
      serve(sock, test_pid, 1, batch_ops)
    end)

    "127.0.0.1:#{port}"
  end

  defp serve(sock, test_pid, handle, batch_ops) do
    with {:ok, <<len::32>>} <- :gen_tcp.recv(sock, 4),
         {:ok, json} <- :gen_tcp.recv(sock, len) do
      req = JSON.decode!(json)
      payload = if n = req["params"]["payload_len"], do: elem(:gen_tcp.recv(sock, n), 1)
      send(test_pid, {:req, req, payload})

      result =
        case req["op"] do
          "hello" -> %{service: "fake", features: ["render.batch"], limits: %{batch_ops: batch_ops}}
          "display.open" -> %{fb_handle: 1, w: req["params"]["w"], h: req["params"]["h"]}
          "surface.create" -> %{handle: handle + 1}
          "frame.commit" -> %{events: [%{kind: 4, x: 5, y: 6, button: 1}]}
          "event.poll" -> %{events: []}
          "render.batch" -> %{count: length(req["params"]["ops"]), errors: 0}
          _ -> %{}
        end

      if req["id"] > 0 do
        out = JSON.encode!(%{v: 2, id: req["id"], ok: true, result: result})
        :gen_tcp.send(sock, <<byte_size(out)::32, out::binary>>)
      end

      serve(sock, test_pid, handle + 1, batch_ops)
    end
  end

  test "negotiates, calls, batches within limits and sends trailers" do
    endpoint = fake_service(self())
    {:ok, conn} = Remote.connect(endpoint, "test/1")
    assert_receive {:req, %{"v" => 2, "id" => 1, "op" => "hello", "params" => %{"protocol" => 2}}, nil}
    assert conn.limits["batch_ops"] == 2

    {:ok, %{"fb_handle" => 1}, conn} = Remote.call(conn, "display.open", %{w: 64, h: 32})

    ops = [Remote.fill(1, 0, 0, 4, 4, 0x112233), Remote.text(1, 0, 0, "héllo", 0xFFFFFF), Remote.line(1, 0, 0, 3, 3, 0)]
    {:ok, conn} = Remote.batch(conn, ops)
    assert_receive {:req, %{"op" => "render.batch", "params" => %{"ops" => [fill, text]}}, nil}
    assert fill["params"]["rgb"] == 0xFF112233
    assert text["params"]["text"] == "h?llo"
    assert_receive {:req, %{"op" => "render.batch", "params" => %{"ops" => [_line]}}, nil}

    {:ok, _, conn} = Remote.call(conn, "surface.upload", %{handle: 2}, <<1, 2, 3, 4>>)
    assert_receive {:req, %{"op" => "surface.upload", "params" => %{"payload_len" => 4}}, <<1, 2, 3, 4>>}

    {:ok, %{"events" => [%{"kind" => 4}]}, _conn} = Remote.call(conn, "frame.commit")
  end

  test "the desktop service draws and handles input against a protocol service" do
    endpoint = fake_service(self())
    {:ok, pid} = SSI.Desktop.start_link(%{endpoint: endpoint, size: "800x600"})
    assert_receive {:req, %{"op" => "display.open", "params" => %{"w" => 800, "h" => 600}}, nil}, 5_000
    assert_receive {:req, %{"op" => "render.batch"}, nil}, 5_000
    assert_receive {:req, %{"op" => "frame.commit"}, nil}, 5_000
    # Mandelbrot tiles computed by the cluster are uploaded as pixel trailers.
    assert_receive {:req, %{"op" => "surface.upload"}, pixels}, 20_000
    assert byte_size(pixels) == 50 * 50 * 4
    status = GenServer.call(pid, :status)
    assert status.connected and status.frames >= 1
    assert SSI.Desktop.ShellApp in status.windows
    GenServer.stop(pid)
  end

  test "a complete tile burst is delivered across bounded frames" do
    endpoint = fake_service(self(), 512)
    {:ok, pid} = SSI.Desktop.start_link(%{endpoint: endpoint, size: "800x600"})
    assert_receive {:req, %{"op" => "frame.commit"}, nil}, 5_000
    :sys.suspend(pid)
    state = :sys.get_state(pid)
    win = Enum.find(state.windows, &(&1.app == SSI.Desktop.MandelbrotApp))
    gen = win.state.gen + 1
    :sys.replace_state(pid, fn state ->
      windows = Enum.map(state.windows, fn w ->
        if w.id == win.id, do: %{w | state: %{w.state | gen: gen, tiles: %{}, pending: []}}, else: w
      end)
      %{state | windows: windows, upload_queue: %{}, dirty: true}
    end)
    pixels = :binary.copy(<<19, 71, 113, 255>>, 2500)
    for i <- 0..95, do: send(pid, {:app, win.id, {:tile, gen, i, node(), pixels}})
    drain_requests()
    :sys.resume(pid)
    collect_tiles(96, 0, pixels)
    assert GenServer.call(pid, :status).connected
    GenServer.stop(pid)
  end

  defp drain_requests do
    receive do
      {:req, _, _} -> drain_requests()
    after
      0 -> :ok
    end
  end

  defp collect_tiles(remaining, in_frame, pixels) do
    receive do
      {:req, %{"op" => "surface.upload"}, ^pixels} ->
        collect_tiles(remaining - 1, in_frame + 1, pixels)
      {:req, %{"op" => "surface.upload"}, _} ->
        collect_tiles(remaining, in_frame + 1, pixels)
      {:req, %{"op" => "frame.commit"}, nil} ->
        assert in_frame <= 8
        if remaining > 0, do: collect_tiles(remaining, 0, pixels)
      {:req, _, _} ->
        collect_tiles(remaining, in_frame, pixels)
    after
      15_000 -> flunk("queued tiles did not reach the renderer")
    end
  end

end
