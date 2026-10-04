defmodule SSI.Cluster.TLS do
  @moduledoc """
  Certificates for TLS-encrypted, mutually authenticated distribution.

  Every node derives the same cluster CA *key* from the cluster secret, so no
  certificate has to be provisioned or copied between machines. At boot a node
  issues itself a certificate for a fresh private key, signed by that CA.
  Distribution (`inet_tls_dist`, configured by `rel/overlays/ssl_dist.conf`)
  then requires both ends to present a certificate the CA key signed: a host
  that does not know the secret can neither read cluster traffic nor join.

  The CA certificate is a pure function of the secret (fixed serial and
  validity, deterministic Ed25519 signature), so every node holds the
  byte-identical trust anchor that peers send during the handshake.
  """

  @curve {:namedCurve, :secp256r1}
  @dir "/run/ssi/tls"

  def dir, do: @dir

  @doc "Write `ca.pem`, `node.pem` and `node.key` for this boot into `dir`."
  def install(dir \\ @dir) do
    m = material(SSI.Config.get("secret"), SSI.Cluster.Identity.cluster(), node_name())
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "ca.pem"), pem(:Certificate, m.ca))
    File.write!(Path.join(dir, "node.pem"), pem(:Certificate, m.cert))
    File.write!(Path.join(dir, "node.key"), pem(m.key_type, m.key))
    File.chmod!(Path.join(dir, "node.key"), 0o600)
    :ok
  end

  @doc """
  Pure derivation, for tests and `install/1`: the cluster CA certificate, and
  a certificate plus private key for this node, all DER.
  """
  def material(secret, cluster, name) do
    ca_key = ca_key(secret, cluster)
    ca = ca_cert(ca_key, cluster)

    conf =
      :public_key.pkix_test_data(%{
        server_chain: %{root: %{cert: ca, key: ca_key}, peer: [key: @curve, digest: :sha256, extensions: [san(name)]]},
        client_chain: %{root: %{cert: ca, key: ca_key}, peer: [key: @curve, digest: :sha256]}
      })

    server = conf[:server_config]
    {key_type, key_der} = server[:key]
    leaf = rewrite(server[:cert], ca_key, fn tbs -> put_elem(tbs, 6, dn(name)) end)
    %{ca: ca, cert: leaf, key_type: key_type, key: key_der}
  end

  # TLS peers send their CA certificate with their own, and a receiver only
  # accepts it as the trust anchor if it is byte-identical to its copy. So the
  # CA certificate must be a pure function of the secret: fixed serial, fixed
  # validity, a real subject, and an Ed25519 signature (deterministic).
  defp ca_cert(ca_key, cluster) do
    seed = :public_key.pkix_test_root_cert(~c"ElixirSSI", key: ca_key)

    rewrite(seed.cert, ca_key, fn tbs ->
      name = dn("ElixirSSI cluster #{cluster} CA")

      tbs
      |> put_elem(2, 1)
      |> put_elem(4, name)
      |> put_elem(5, {:Validity, {:utcTime, ~c"260101000000Z"}, {:generalTime, ~c"21260101000000Z"}})
      |> put_elem(6, name)
    end)
  end

  defp rewrite(der, signer, fun) do
    {:OTPCertificate, tbs, _alg, _sig} = :public_key.pkix_decode_cert(der, :otp)
    :public_key.pkix_sign(fun.(tbs), signer)
  end

  defp dn(common_name) do
    {:rdnSequence, [[{:AttributeTypeAndValue, {2, 5, 4, 3}, {:utf8String, common_name}}]]}
  end

  @doc "ssl options equivalent to the distribution configuration (tests)."
  def ssl_opts(dir, :server), do: [{:fail_if_no_peer_cert, true} | ssl_opts(dir, :client)]

  def ssl_opts(dir, :client) do
    [
      certfile: Path.join(dir, "node.pem") |> String.to_charlist(),
      keyfile: Path.join(dir, "node.key") |> String.to_charlist(),
      cacertfile: Path.join(dir, "ca.pem") |> String.to_charlist(),
      verify: :verify_peer,
      versions: [:"tlsv1.3"]
    ]
  end

  defp ca_key(secret, cluster) do
    seed = :crypto.mac(:hmac, :sha256, secret, "tls-ca:" <> cluster)
    {pub, ^seed} = :crypto.generate_key(:eddsa, :ed25519, seed)
    {:ECPrivateKey, :ecPrivkeyVer1, seed, {:namedCurve, {1, 3, 101, 112}}, pub, :asn1_NOVALUE}
  end

  defp san(name) do
    {:Extension, {2, 5, 29, 17}, false, [dNSName: String.to_charlist(name)]}
  end

  defp node_name, do: SSI.Boot.hostname() || "ssi"

  defp pem(type, der), do: :public_key.pem_encode([{type, der, :not_encrypted}])
end
