defmodule SSI.WebTest do
  use ExUnit.Case, async: false
  import SSI.TestWS

  setup_all do
    {:ok, pid} = SSI.Web.start_link(port: 0, name: :web_test)
    port = wait_port(:web_test)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    %{port: port}
  end

  test "status as JSON, readable from any origin", %{port: port} do
    {status, headers, body} = http(connect(port), "GET /api/status HTTP/1.1\r\nhost: x\r\norigin: null\r\n\r\n")
    assert status == 200
    assert headers["access-control-allow-origin"] == "*"
    assert headers["content-type"] == "application/json"
    assert %{"schema" => "elixirssi-status/1", "observer" => %{"node" => node}} = JSON.decode!(body)
    assert node == to_string(node())
  end

  test "preflight from a page on a public origin", %{port: port} do
    {status, headers, _} =
      http(connect(port), "OPTIONS /api/status HTTP/1.1\r\nhost: x\r\naccess-control-request-private-network: true\r\n\r\n")

    assert status == 204
    assert headers["access-control-allow-private-network"] == "true"
  end

  test "the monitor page", %{port: port} do
    {200, headers, body} = http(connect(port), "GET / HTTP/1.1\r\nhost: x\r\n\r\n")
    assert headers["content-type"] =~ "text/html"
    assert body =~ "ElixirSSI monitor"
    refute body =~ ~r/<(script|link|img)[^>]+(src|href)="?https?:/
  end

  test "no other methods or paths", %{port: port} do
    assert {405, _, _} = http(connect(port), "POST /api/status HTTP/1.1\r\nhost: x\r\ncontent-length: 0\r\n\r\n")
    assert {404, _, _} = http(connect(port), "GET /etc/passwd HTTP/1.1\r\nhost: x\r\n\r\n")
    assert {426, _, _} = http(connect(port), "GET /api/stream HTTP/1.1\r\nhost: x\r\n\r\n")
  end

  test "the stream: a challenge, a snapshot with the journal, events, ping, close", %{port: port} do
    s = connect(port)
    {head, rest} = upgrade(s)
    assert head =~ "101 Switching Protocols"
    # RFC 6455's own example key and accept value.
    assert head =~ "sec-websocket-accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo="

    {%{"type" => "hello", "challenge" => challenge, "tls" => false}, rest} = recv_json(s, rest)
    assert byte_size(Base.decode64!(challenge)) == 32

    {%{"type" => "snapshot", "status" => first}, rest} = recv_json(s, rest)
    assert is_list(first["journal"])

    {%{"type" => "snapshot", "status" => next}, rest} = recv_json(s, rest)
    refute Map.has_key?(next, "journal")

    event = %{id: "test-1", at: 1, kind: "test", subject: "x", origin: "here", detail: %{}}
    SSI.Events.publish(:journal, {:ssi_journal, event})
    {msg, rest} = recv_until(s, rest, &(&1["type"] == "event"))
    assert msg["event"]["id"] == "test-1"

    :ok = send_data(s, masked(0x9, "hi"))
    {{0xA, "hi"}, rest} = recv_frame_until(s, rest, &(elem(&1, 0) == 0xA))

    :ok = send_data(s, masked(0x8, <<1000::16>>))
    {{0x8, _}, _} = recv_frame_until(s, rest, &(elem(&1, 0) == 0x8))
  end

  test "frame lengths" do
    for len <- [0, 125, 126, 65_535, 65_536] do
      payload = :binary.copy("a", len)
      bin = IO.iodata_to_binary(SSI.Web.frame(0x1, payload))
      assert {0x1, ^payload, ""} = unframe(bin)
    end

    assert SSI.Web.decode(IO.iodata_to_binary(masked(0x1, "abc"))) == {:frame, 0x1, "abc", ""}
    assert SSI.Web.decode(<<0x81, 3, "abc">>) == :error
    assert SSI.Web.decode(<<0x81>>) == :more
  end
end
