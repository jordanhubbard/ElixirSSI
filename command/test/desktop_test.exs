defmodule ElixirSSI.Command.DesktopTest do
  use ExUnit.Case, async: false
  alias ElixirSSI.Command.Desktop

  test "TCP reconnects require fresh authentication and malformed envelopes leave the bridge alive" do
    pid = Process.whereis(Desktop)
    {:ok, {_, port}} = :inet.sockname(:sys.get_state(Desktop).listener)

    connect = fn ->
      {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 1000)
      socket
    end

    send_request = fn socket, op, params ->
      bytes = Jason.encode!(%{v: 2, id: 1, op: op, params: params})
      :gen_tcp.send(socket, [<<byte_size(bytes)::32>>, bytes])
    end

    reply = fn socket ->
      {:ok, <<length::32>>} = :gen_tcp.recv(socket, 4, 1000)
      {:ok, bytes} = :gen_tcp.recv(socket, length, 1000)
      Jason.decode!(bytes)
    end

    socket = connect.()
    send_request.(socket, "hello", %{"protocol" => 2, "token" => GenServer.call(Desktop, :token)})
    assert %{"ok" => true} = reply.(socket)
    :gen_tcp.close(socket)
    socket = connect.()
    send_request.(socket, "display.open", %{"w" => 1280, "h" => 800})
    assert %{"ok" => false} = reply.(socket)
    :gen_tcp.close(socket)
    socket = connect.()
    send_request.(socket, "hello", "not a parameter map")
    assert {:error, :closed} = :gen_tcp.recv(socket, 4, 1000)
    assert Process.whereis(Desktop) == pid
  end

  defp request(session, op, params, payload \\ <<>>),
    do: GenServer.call(Desktop, {:request, session, op, params, payload})

  test "desktop sessions authenticate independently and reject unsupported drawing" do
    session = make_ref()
    token = GenServer.call(Desktop, :token)
    assert {:error, _} = request(session, "display.open", %{"w" => 1280, "h" => 800})
    assert {:error, _} = request(session, "hello", %{"protocol" => 2, "token" => "wrong"})
    assert {:ok, _} = request(session, "hello", %{"protocol" => 2, "token" => token})
    assert {:error, _} = request(make_ref(), "display.open", %{"w" => 1280, "h" => 800})
    assert {:ok, %{fb_handle: 1}} = request(session, "display.open", %{"w" => 1280, "h" => 800})
    assert {:error, _} = request(session, "surface.create", %{"w" => 100_000, "h" => 100_000})
    assert {:ok, %{handle: handle}} = request(session, "surface.create", %{"w" => 2, "h" => 2})
    assert {:error, _} = request(session, "surface.upload", %{"handle" => handle}, <<0>>)
    pixels = :binary.copy(<<0, 0, 255, 255>>, 4)
    assert {:ok, _} = request(session, "surface.upload", %{"handle" => handle}, pixels)
    assert {:error, _} = request(session, "render.batch", %{"ops" => [%{"op" => "file.write"}]})

    ops = [
      %{
        "op" => "surface.blit",
        "params" => %{
          "src" => handle,
          "dst" => 1,
          "dst_rect" => %{"x" => 0, "y" => 0, "w" => 2, "h" => 2}
        }
      }
    ]

    assert {:ok, _} = request(session, "render.batch", %{"ops" => ops})
    event = %{"kind" => 1, "code" => 13, "text" => ""}
    Desktop.input(event)
    assert {:ok, %{events: [^event]}} = request(session, "frame.commit", %{})
    assert %{ops: ^ops, connected: true, surfaces: surfaces} = Desktop.frame()
    assert surfaces[handle].pixels == Base.encode64(pixels)
    assert {:ok, %{events: []}} = request(session, "event.poll", %{})
    GenServer.cast(Desktop, {:closed, session})
    assert %{connected: false} = Desktop.frame()
    assert {:error, _} = request(session, "event.poll", %{})
  end

  test "independent demo surfaces can coexist and destroyed handles do not collide" do
    session = make_ref()
    token = GenServer.call(Desktop, :token)
    assert {:ok, _} = request(session, "hello", %{"protocol" => 2, "token" => token})
    assert {:ok, _} = request(session, "display.open", %{"w" => 1280, "h" => 800})

    handles =
      for _ <- 1..192 do
        assert {:ok, %{handle: handle}} =
                 request(session, "surface.create", %{"w" => 50, "h" => 50})

        handle
      end

    assert Enum.uniq(handles) == handles
    assert {:ok, _} = request(session, "surface.destroy", %{"handle" => hd(handles)})

    assert {:ok, %{handle: replacement}} =
             request(session, "surface.create", %{"w" => 50, "h" => 50})

    refute replacement in tl(handles)
    assert {:error, _} = request(session, "surface.destroy", %{"handle" => 1})
    GenServer.cast(Desktop, {:closed, session})
  end
end
