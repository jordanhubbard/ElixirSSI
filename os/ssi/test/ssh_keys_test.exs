defmodule SSI.SSHKeysTest do
  use ExUnit.Case, async: false

  test "fresh cluster identities agree before replication and remain secret-specific" do
    keys = for _ <- 1..3, do: Task.async(fn -> SSI.SSH.Keys.derive_host_key("test secret", "cluster") end)
    [key, key, key] = Enum.map(keys, &Task.await/1)
    refute key == SSI.SSH.Keys.derive_host_key("another secret", "cluster")
    refute key == SSI.SSH.Keys.derive_host_key("test secret", "another cluster")
    signature = :public_key.sign("identity check", :none, key)
    assert :public_key.verify("identity check", :none, signature, {{:ECPoint, elem(key, 4)}, elem(key, 3)})
  end

  test "a stored legacy host key survives adoption" do
    previous = SSI.Store.get(:system, :ssh_host_key)
    on_exit(fn ->
      if previous, do: SSI.Store.put(:system, :ssh_host_key, previous), else: SSI.Store.delete(:system, :ssh_host_key)
    end)
    legacy = :public_key.generate_key({:namedCurve, :ed25519})
    SSI.Store.delete(:system, :ssh_host_key)
    expected = SSI.SSH.Keys.derive_host_key(SSI.Config.get("secret"), SSI.Cluster.Identity.cluster())
    assert {:ok, ^expected} = SSI.SSH.Keys.host_key(:"ssh-ed25519", [])
    assert SSI.Store.get(:system, :ssh_host_key) == nil
    SSI.Store.put(:system, :ssh_host_key, legacy)
    assert {:ok, ^legacy} = SSI.SSH.Keys.host_key(:"ssh-ed25519", [])
  end
end
