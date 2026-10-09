defmodule ElixirSSI.Command.RemoteTest.Keys do
  @behaviour :ssh_server_key_api
  def host_key(:"ssh-ed25519", _), do: {:ok, :persistent_term.get(__MODULE__)}
  def host_key(_, _), do: {:error, :unsupported}
  def is_auth_key(_, _, _), do: false
end

defmodule ElixirSSI.Command.RemoteTest do
  use ExUnit.Case, async: false
  alias ElixirSSI.Command.Remote
  alias ElixirSSI.Command.RemoteTest.Keys

  test "SSH identity inspection, explicit trust and exec work with the shipped OTP" do
    :persistent_term.put(Keys, :public_key.generate_key({:namedCurve, :ed25519}))

    {:ok, daemon} =
      :ssh.daemon(0,
        ip: {127, 0, 0, 1},
        key_cb: {Keys, []},
        auth_methods: ~c"password",
        pwdfun: fn _, password -> password == ~c"test-only" end,
        shell: :disabled,
        exec: {:direct, fn _ -> {:ok, ~c"42"} end}
      )

    on_exit(fn ->
      :ssh.stop_daemon(daemon)
      :persistent_term.erase(Keys)
    end)

    info = :ssh.daemon_info(daemon, [:port])
    port = info[:port]
    assert {:ok, fingerprint} = Remote.probe("127.0.0.1", port)
    assert String.starts_with?(fingerprint, "SHA256:")
    assert {:error, _} = Remote.trust("127.0.0.1", port, "wrong fingerprint", "test-only")
    assert {:error, _} = Remote.trust("127.0.0.1", port, fingerprint, "wrong password")
    refute "127.0.0.1|#{port}" in Remote.targets()
    assert {:ok, _} = Remote.trust("127.0.0.1", port, fingerprint, "test-only")
    assert {:ok, "42"} = Remote.evaluate("127.0.0.1|#{port}", "6 * 7")
    assert {:ok, "42"} = Remote.evaluate("127.0.0.1|#{port}", String.duplicate(" ", 200_000))
    assert {:error, _} = Remote.evaluate("127.0.0.1|#{port}", String.duplicate(" ", 240_001))
    :persistent_term.put(Keys, :public_key.generate_key({:namedCurve, :ed25519}))
    assert {:error, _} = Remote.evaluate("127.0.0.1|#{port}", "6 * 7")
  end
end
