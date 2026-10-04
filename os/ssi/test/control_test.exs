defmodule SSI.ControlTest do
  # Monitor controls: pairing, signed requests, and the endpoint over TLS.
  use ExUnit.Case, async: false
  import SSI.TestWS
  import SSI.TestCluster

  alias SSI.Web.Control
  alias SSI.TestWork.Counter

  setup_all do
    {:ok, _} = Application.ensure_all_started(:ssl)
    {:ok, pid} = SSI.Web.start_link(port: 0, tls_port: 0, name: :control_web)
    plain = wait_port(:control_web)
    tls = wait_port(:control_web, :tls)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    %{port: plain, tls_port: tls}
  end

  setup do
    on_exit(fn -> for k <- Control.keys(), do: Control.revoke(k.id) end)
  end

  describe "pairing" do
    test "a code pairs one browser key, once, on every member", %{port: port} do
      code = Control.pair("laptop")
      assert code =~ ~r/^[A-Z2-7]{4}(-[A-Z2-7]{4}){3}$/
      browser = key()

      {s, rest, challenge} = open(port)
      {wrong, rest} = request(s, rest, pair_msg(browser, "AAAA-AAAA-AAAA-AAAA", challenge, 1))
      assert %{"ok" => false, "error" => "pairing refused" <> _} = wrong
      assert Control.keys() == []

      {right, rest} = request(s, rest, pair_msg(browser, code, challenge, 2))
      assert %{"ok" => true, "value" => %{"id" => id, "name" => "laptop"}} = right
      assert id == Control.key_id(browser.pub)
      assert [%{id: ^id, name: "laptop", via: "pairing code"}] = Control.keys()

      # Snapshots name the trusted keys by id, so the monitor knows it is paired.
      {snap, _} = recv_until(s, rest, &(&1["type"] == "snapshot"))
      assert id in snap["status"]["control"]["keys"]

      # The code is spent.
      other = key()
      {s2, rest2, challenge2} = open(port)
      {again, _} = request(s2, rest2, pair_msg(other, code, challenge2, 1))
      assert again["ok"] == false
      assert length(Control.keys()) == 1
    end

    test "an expired code is refused", %{port: port} do
      code = Control.pair("old")
      raw = String.replace(code, "-", "")
      SSI.Store.put_sync(:monitor_pairing, raw, %{name: "old", expires: System.os_time(:millisecond) - 1})
      {s, rest, challenge} = open(port)
      {reply, _} = request(s, rest, pair_msg(key(), code, challenge, 1))
      assert reply["ok"] == false
      assert Control.keys() == []
    end
  end

  describe "signed requests" do
    setup do
      peers = start_peers([:"ssi-ctl-a"])
      on_exit(fn -> stop_peers(peers) end)
      [{_, peer}] = peers
      eventually(fn -> SSI.Cluster.members() == Enum.sort([node(), peer]) end)
      :ok = SSI.Service.register(:ctl_counter, Counter, %{}, node: node())
      eventually(fn -> match?({_, n} when n == node(), where(:ctl_counter)) end)
      on_exit(fn -> SSI.Service.unregister(:ctl_counter) end)
      %{peer: peer}
    end

    test "only a trusted key's signature over this connection's challenge changes the system", %{port: port, peer: peer} do
      browser = key()
      stranger = key()
      Control.trust(browser.pub, "ops")
      to = SSI.Cluster.hostname(peer)
      move = fn k, seq -> JSON.encode!(%{key: Control.key_id(k.pub), seq: seq, action: "migrate", service: "ctl_counter", to: to}) end

      {s, rest, challenge} = open(port)

      # Not signed by a trusted key: an untrusted key, a bad signature, no signature.
      {r, rest} = request(s, rest, action_msg(stranger, move.(stranger, 1), challenge))
      assert r == %{"type" => "result", "seq" => 1, "ok" => false, "error" => "unauthorized"}
      {r, rest} = request(s, rest, %{type: "action", request: move.(browser, 2), sig: Base.encode64(:binary.copy(<<1>>, 64))})
      assert r["error"] == "unauthorized"
      {r, rest} = request(s, rest, %{type: "action", request: move.(browser, 3)})
      assert r["error"] == "malformed request"

      # Altered after signing.
      signed = action_msg(browser, move.(browser, 4), challenge)
      {r, rest} = request(s, rest, %{signed | request: String.replace(signed.request, to, "elsewhere")})
      assert r["error"] == "unauthorized"
      assert where(:ctl_counter) |> elem(1) == node()

      # Properly signed: the service moves.
      {r, rest} = request(s, rest, signed)
      assert %{"ok" => true, "seq" => 4, "value" => %{"service" => "ctl_counter", "to" => ^to}} = r
      eventually(fn -> match?({_, ^peer}, where(:ctl_counter)) end, 15_000)

      # Replayed on the same connection, or on another one.
      {r, _} = request(s, rest, signed)
      assert r["error"] == "replayed request"
      {s2, rest2, _} = open(port)
      {r, _} = request(s2, rest2, signed)
      assert r["error"] == "unauthorized"

      # The authenticated request is in the journal, by name.
      assert Enum.any?(SSI.Status.Journal.recent(), &(&1.kind == "control" and &1.subject == "ctl_counter" and &1.detail.by == "ops" and &1.detail.ok))

      # A member that cannot act says so; an unknown member is an error.
      {s3, rest3, challenge3} = open(port)
      power = fn seq, member -> JSON.encode!(%{key: Control.key_id(browser.pub), seq: seq, action: "restart", member: member}) end
      {r, rest3} = request(s3, rest3, action_msg(browser, power.(1, SSI.Boot.hostname()), challenge3))
      assert r["ok"] == false and r["error"] =~ "hosted node"
      {r, rest3} = request(s3, rest3, action_msg(browser, power.(2, "nobody"), challenge3))
      assert r["error"] == "no member nobody"

      # Revoked: refused at once.
      assert Control.revoke("ops") == [Control.key_id(browser.pub)]
      back = JSON.encode!(%{key: Control.key_id(browser.pub), seq: 3, action: "migrate", service: "ctl_counter", to: SSI.Boot.hostname()})
      {r, _} = request(s3, rest3, action_msg(browser, back, challenge3))
      assert r["error"] == "unauthorized"
    end
  end

  describe "TLS" do
    test "the endpoint over TLS with a certificate from the web CA", %{port: port, tls_port: tls_port} do
      {ca, _} = SSI.Web.TLS.ca()
      {200, headers, pem} = http(connect(port), "GET /ca.pem HTTP/1.1\r\nhost: x\r\n\r\n")
      assert headers["content-type"] == "application/x-pem-file"
      assert [{:Certificate, served, _}] = :public_key.pem_decode(pem)

      # Members' copies may differ in signature bytes, never in name or key.
      assert spki(served) == spki(ca)
      assert SSI.Web.TLS.fingerprint() == :crypto.hash(:sha256, spki(served)) |> Base.encode64()

      opts = [verify: :verify_peer, cacerts: [served], server_name_indication: ~c"localhost", versions: [:"tlsv1.3"]]
      s = connect(tls_port, opts)
      {:ssl, sock} = s
      {:ok, cert} = :ssl.peercert(sock)
      assert :public_key.pkix_verify_hostname(cert, ip: {127, 0, 0, 1})
      assert :public_key.pkix_verify_hostname(cert, dns_id: ~c"localhost")
      {200, _, body} = http(s, "GET /api/status HTTP/1.1\r\nhost: x\r\n\r\n")
      assert %{"schema" => "elixirssi-status/1"} = JSON.decode!(body)

      s = connect(tls_port, opts)
      {head, rest} = upgrade(s)
      assert head =~ "101 Switching Protocols"
      assert {%{"type" => "hello", "tls" => true}, _} = recv_json(s, rest)

      # A browser trusting another cluster's CA refuses this member.
      {other, _} = SSI.Web.TLS.ca("another secret", "lab")
      assert {:error, _} = :ssl.connect(~c"127.0.0.1", tls_port, [:binary, active: false, cacerts: [other]] ++ Keyword.delete(opts, :cacerts), 5_000)
    end

    test "the web CA is a pure function of the secret; certificates name the member" do
      assert SSI.Web.TLS.fingerprint("s", "lab") == SSI.Web.TLS.fingerprint("s", "lab")
      refute SSI.Web.TLS.fingerprint("s", "lab") == SSI.Web.TLS.fingerprint("t", "lab")
      {ca, _} = SSI.Web.TLS.ca("s", "lab")
      leaf = SSI.Web.TLS.leaf(SSI.Web.TLS.new_key(), "ssi-7", [{10, 0, 2, 15}], "s", "lab")
      assert {:ok, _} = :public_key.pkix_path_validation(ca, [leaf], [])
      assert :public_key.pkix_verify_hostname(leaf, ip: {10, 0, 2, 15})
      assert :public_key.pkix_verify_hostname(leaf, dns_id: ~c"ssi-7")
      refute :public_key.pkix_verify_hostname(leaf, ip: {10, 0, 2, 16})

      # A member's key is the same at every boot, and its own.
      assert SSI.Web.TLS.member_key("ssi-7", "s", "lab") == SSI.Web.TLS.member_key("ssi-7", "s", "lab")
      refute SSI.Web.TLS.member_key("ssi-7", "s", "lab") == SSI.Web.TLS.member_key("ssi-8", "s", "lab")
    end
  end

  # -- a browser, as far as the endpoint can tell -----------------------------------

  defp key do
    {pub, priv} = :crypto.generate_key(:ecdh, :secp256r1)
    %{pub: pub, priv: priv}
  end

  # WebCrypto's ECDSA signature format: r || s.
  defp sign(k, data) do
    der = :crypto.sign(:ecdsa, :sha256, data, [k.priv, :secp256r1])
    {:"ECDSA-Sig-Value", r, s} = :public_key.der_decode(:"ECDSA-Sig-Value", der)
    <<r::256, s::256>>
  end

  defp pair_msg(k, code, challenge, seq) do
    req = JSON.encode!(%{seq: seq, key: Base.url_encode64(k.pub, padding: false)})
    mac = :crypto.mac(:hmac, :sha256, String.replace(code, "-", ""), "elixirssi-pair/1\n" <> challenge <> "\n" <> req)
    %{type: "pair", request: req, mac: Base.encode64(mac)}
  end

  defp action_msg(k, req, challenge) do
    %{type: "action", request: req, sig: Base.encode64(sign(k, "elixirssi-action/1\n" <> challenge <> "\n" <> req))}
  end

  defp open(port) do
    s = connect(port)
    {_head, rest} = upgrade(s)
    {%{"type" => "hello", "challenge" => challenge}, rest} = recv_json(s, rest)
    {s, rest, challenge}
  end

  defp request(s, rest, msg) do
    send_text(s, JSON.encode!(msg))
    recv_until(s, rest, &(&1["type"] == "result"))
  end

  defp where(name) do
    case SSI.Service.whereis(name) do
      pid when is_pid(pid) -> {pid, node(pid)}
      other -> {other, nil}
    end
  end

  defp spki(der) do
    {:Certificate, tbs, _, _} = :public_key.pkix_decode_cert(der, :plain)
    :public_key.der_encode(:SubjectPublicKeyInfo, elem(tbs, 7))
  end
end
