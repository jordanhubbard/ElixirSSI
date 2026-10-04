defmodule SSI.Web.TLS do
  @moduledoc """
  Certificates for the status endpoint over HTTPS.

  Browsers do not accept Ed25519 in certificates, so the endpoint cannot use
  the distribution CA (`SSI.Cluster.TLS`). It has its own *web CA*, whose
  ECDSA P-256 key is derived from the cluster secret: the same on every
  member and across every restart, and never stored. An operator trusts it
  once in the browser (`GET /ca.pem`, checked against `fingerprint/0`).

  Each member issues itself a certificate from that CA, naming its host
  name, `localhost`, and every address it has (loopback included, so a port
  forward or SSH tunnel verifies too); it is issued again when the addresses
  change. Its key is derived from the secret and the host name, so a member
  presents the same key after every boot and a browser may pin it (TLS 1.3
  key exchange is ephemeral, so recorded sessions stay private even so). Validity is fixed (2026 to 2126)
  because a member may boot without a clock. The CA certificate is not sent
  in the handshake: the browser builds the chain from the copy it trusts
  (ECDSA signatures are not deterministic, so members' copies differ in
  their signature bytes, though never in name or key).
  """

  @p256 {1, 2, 840, 10045, 3, 1, 7}
  @ec_public_key {1, 2, 840, 10045, 2, 1}
  @ecdsa_sha256 {1, 2, 840, 10045, 4, 3, 2}
  @order 0xFFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551
  @validity {:Validity, {:utcTime, ~c"260101000000Z"}, {:generalTime, ~c"21260101000000Z"}}

  @doc "The web CA certificate (DER) and private key for `secret` and `cluster`."
  def ca(secret \\ SSI.Config.get("secret"), cluster \\ SSI.Cluster.Identity.cluster()) do
    key = ca_key(secret, cluster)
    name = dn("ElixirSSI cluster #{cluster} web CA")

    extensions = [
      ext({2, 5, 29, 19}, true, {:BasicConstraints, true, 0}),
      ext({2, 5, 29, 15}, true, [:keyCertSign, :cRLSign]),
      ext({2, 5, 29, 14}, false, key_id(key))
    ]

    {:public_key.pkix_sign(tbs(1, name, name, spki(key), extensions), key), key}
  end

  @doc "PEM text of the web CA certificate."
  def ca_pem, do: :public_key.pem_encode([{:Certificate, elem(ca(), 0), :not_encrypted}])

  @doc "SHA-256 of the web CA's public key (SubjectPublicKeyInfo), base64: what an operator checks."
  def fingerprint(secret \\ SSI.Config.get("secret"), cluster \\ SSI.Cluster.Identity.cluster()) do
    {der, _} = ca(secret, cluster)
    {:Certificate, tbs, _, _} = :public_key.pkix_decode_cert(der, :plain)
    :crypto.hash(:sha256, :public_key.der_encode(:SubjectPublicKeyInfo, elem(tbs, 7))) |> Base.encode64()
  end

  @doc """
  A certificate (DER) for `key`, issued by the web CA, naming `hostname`,
  `localhost` and `ips` (address tuples).
  """
  def leaf(key, hostname, ips, secret \\ SSI.Config.get("secret"), cluster \\ SSI.Cluster.Identity.cluster()) do
    {ca_der, ca_key} = ca(secret, cluster)
    {:OTPCertificate, ca_tbs, _, _} = :public_key.pkix_decode_cert(ca_der, :otp)

    names =
      Enum.uniq(for(n <- [hostname, "localhost"], n, do: {:dNSName, String.to_charlist(n)})) ++
        for(ip <- Enum.uniq([{127, 0, 0, 1} | ips]), do: {:iPAddress, Tuple.to_list(ip)})

    extensions = [
      ext({2, 5, 29, 19}, true, {:BasicConstraints, false, :asn1_NOVALUE}),
      ext({2, 5, 29, 15}, true, [:digitalSignature]),
      ext({2, 5, 29, 37}, false, [{1, 3, 6, 1, 5, 5, 7, 3, 1}]),
      ext({2, 5, 29, 17}, false, names),
      ext({2, 5, 29, 35}, false, {:AuthorityKeyIdentifier, key_id(ca_key), :asn1_NOVALUE, :asn1_NOVALUE})
    ]

    serial = :crypto.strong_rand_bytes(15) |> :binary.decode_unsigned()
    :public_key.pkix_sign(tbs(serial, elem(ca_tbs, 6), dn(hostname || "ssi"), spki(key), extensions), ca_key)
  end

  @doc "A fresh P-256 private key."
  def new_key, do: :public_key.generate_key({:namedCurve, @p256})

  @doc "The member's own P-256 key, derived from the secret, cluster and host name."
  def member_key(hostname, secret \\ SSI.Config.get("secret"), cluster \\ SSI.Cluster.Identity.cluster()) do
    derive_key(secret, "web-member:#{cluster}:#{hostname}")
  end

  @doc """
  `:ssl` server options for this member now: its key and a certificate for
  its current host name and addresses (reissued when they change).
  """
  def server_opts do
    host = SSI.Boot.hostname()
    ips = for %{ip: ip} <- addresses(), tuple_size(ip) == 4, do: ip
    id = {host, Enum.sort(ips), SSI.Config.get("secret"), SSI.Cluster.Identity.cluster()}

    {key, cert} =
      case :persistent_term.get({__MODULE__, :cert}, nil) do
        {^id, key, der} ->
          {key, der}

        _ ->
          key = member_key(host)
          der = leaf(key, host, ips)
          :persistent_term.put({__MODULE__, :cert}, {id, key, der})
          {key, der}
      end

    [
      certs_keys: [%{cert: cert, key: {:ECPrivateKey, :public_key.der_encode(:ECPrivateKey, key)}}],
      versions: [:"tlsv1.3", :"tlsv1.2"]
    ]
  end

  defp addresses do
    if Process.whereis(SSI.Net), do: SSI.Net.addresses(), else: []
  catch
    :exit, _ -> []
  end

  # -- certificate parts ---------------------------------------------------------

  defp ca_key(secret, cluster), do: derive_key(secret, "web-ca:" <> cluster)

  # A P-256 private scalar from the secret: HMAC output, redrawn in the rare
  # case it is not below the group order.
  defp derive_key(secret, purpose, counter \\ 0) do
    seed = :crypto.mac(:hmac, :sha256, secret, "#{purpose}:#{counter}")
    n = :binary.decode_unsigned(seed)

    if n == 0 or n >= @order do
      derive_key(secret, purpose, counter + 1)
    else
      {pub, _} = :crypto.generate_key(:ecdh, :secp256r1, seed)
      {:ECPrivateKey, :ecPrivkeyVer1, seed, {:namedCurve, @p256}, pub, :asn1_NOVALUE}
    end
  end

  defp tbs(serial, issuer, subject, spki, extensions) do
    {:OTPTBSCertificate, :v3, serial, {:SignatureAlgorithm, @ecdsa_sha256, :asn1_NOVALUE}, issuer, @validity, subject,
     spki, :asn1_NOVALUE, :asn1_NOVALUE, extensions}
  end

  defp spki({:ECPrivateKey, _, _, params, pub, _}) do
    {:OTPSubjectPublicKeyInfo, {:PublicKeyAlgorithm, @ec_public_key, params}, {:ECPoint, pub}}
  end

  defp key_id({:ECPrivateKey, _, _, _, pub, _}), do: :crypto.hash(:sha, pub)

  defp ext(id, critical, value), do: {:Extension, id, critical, value}

  defp dn(common_name) do
    {:rdnSequence, [[{:AttributeTypeAndValue, {2, 5, 4, 3}, {:utf8String, common_name}}]]}
  end
end
