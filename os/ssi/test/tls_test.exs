defmodule SSI.TLSTest do
  use ExUnit.Case, async: true
  alias SSI.Cluster.TLS

  setup_all do
    {:ok, _} = Application.ensure_all_started(:ssl)
    :ok
  end

  defp node_dir(secret, name) do
    dir = Path.join(System.tmp_dir!(), "ssi-tls-#{name}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    m = TLS.material(secret, "lab", name)
    pem = fn type, der -> :public_key.pem_encode([{type, der, :not_encrypted}]) end
    File.write!(Path.join(dir, "ca.pem"), pem.(:Certificate, m.ca))
    File.write!(Path.join(dir, "node.pem"), pem.(:Certificate, m.cert))
    File.write!(Path.join(dir, "node.key"), pem.(m.key_type, m.key))
    dir
  end

  defp handshake(server_dir, client_dir) do
    {:ok, listen} = :ssl.listen(0, [:binary, active: false, reuseaddr: true] ++ TLS.ssl_opts(server_dir, :server))
    {:ok, {_, port}} = :ssl.sockname(listen)

    server =
      Task.async(fn ->
        with {:ok, t} <- :ssl.transport_accept(listen, 5_000), {:ok, s} <- :ssl.handshake(t, 5_000) do
          :ssl.send(s, "hello")
          :ok
        end
      end)

    client = :ssl.connect(~c"127.0.0.1", port, [:binary, active: false, server_name_indication: :disable] ++ TLS.ssl_opts(client_dir, :client), 5_000)

    result =
      with {:ok, s} <- client, {:ok, data} <- :ssl.recv(s, 0, 5_000) do
        {:ok, data}
      end

    server_result = Task.await(server, 10_000)
    :ssl.close(listen)
    {result, server_result}
  end

  test "nodes deriving from the same secret authenticate each other" do
    a = node_dir("cluster-secret", "ssi-a")
    b = node_dir("cluster-secret", "ssi-b")
    assert {{:ok, "hello"}, :ok} = handshake(a, b)
    assert {{:ok, "hello"}, :ok} = handshake(b, a)
  end

  test "a node without the secret is refused in either role" do
    a = node_dir("cluster-secret", "ssi-a")
    intruder = node_dir("guessed-secret", "ssi-x")
    {client, server} = handshake(a, intruder)
    assert {:error, {:tls_alert, _}} = client
    assert {:error, {:tls_alert, _}} = server
    {client, server} = handshake(intruder, a)
    assert {:error, {:tls_alert, _}} = client
    refute server == :ok
  end
end

defmodule SSI.TLSDeterminismTest do
  use ExUnit.Case, async: true

  test "the cluster CA certificate is identical however and wherever it is derived" do
    # Burn unique integers and time so nothing incidental can leak into the CA.
    a = SSI.Cluster.TLS.material("s", "lab", "ssi-a").ca
    for _ <- 1..100, do: System.unique_integer([:positive, :monotonic])
    Process.sleep(1100)
    b = SSI.Cluster.TLS.material("s", "lab", "ssi-b").ca
    assert a == b
    refute a == SSI.Cluster.TLS.material("other", "lab", "ssi-a").ca
  end
end

defmodule SSI.TLSDistributionTest do
  # Separate BEAMs speaking inet_tls_dist with the shipped option file: the
  # check an in-process handshake cannot make (each node derives its own CA).
  use ExUnit.Case, async: false

  defp peer(name, secret) do
    dir = Path.join(System.tmp_dir!(), "ssi-tlsdist-#{name}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    m = SSI.Cluster.TLS.material(secret, "lab", "#{name}")
    pem = fn type, der -> :public_key.pem_encode([{type, der, :not_encrypted}]) end
    File.write!(Path.join(dir, "ca.pem"), pem.(:Certificate, m.ca))
    File.write!(Path.join(dir, "node.pem"), pem.(:Certificate, m.cert))
    File.write!(Path.join(dir, "node.key"), pem.(m.key_type, m.key))
    conf = Path.join(dir, "ssl_dist.conf")
    File.write!(conf, File.read!("rel/overlays/ssl_dist.conf") |> String.replace("/run/ssi/tls", dir))

    {:ok, pid, node} =
      :peer.start_link(%{
        name: name,
        host: ~c"127.0.0.1",
        longnames: true,
        connection: :standard_io,
        args: [~c"-proto_dist", ~c"inet_tls", ~c"-ssl_dist_optfile", String.to_charlist(conf), ~c"-setcookie", ~c"c"]
      })

    {pid, node}
  end

  test "nodes connect over TLS distribution only with the cluster secret" do
    {a, _} = peer(:"tls-a", "cluster-secret")
    {_b, b_node} = peer(:"tls-b", "cluster-secret")
    {x, _} = peer(:"tls-x", "wrong-secret")

    assert :peer.call(a, :net_adm, :ping, [b_node], 15_000) == :pong
    assert :peer.call(x, :net_adm, :ping, [b_node], 15_000) == :pang
  end
end
