defmodule SSI.SSH do
  @moduledoc """
  SSH access to the system shell, on every member.

  Uses OTP's own SSH server. The host key is generated once per *cluster* and
  kept in the replicated store, so every node presents the same identity: one
  `known_hosts` entry covers the machine no matter which Pi answers.
  Authorised keys come from `/boot/authorized_keys` and the store
  (`SSI.SSH.authorize/1`); password login is enabled only when `ssh.password`
  is configured.
  """
  use GenServer
  require Logger

  def start_link(_), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @doc "Add an OpenSSH public key line to the cluster's authorised keys."
  def authorize(line) do
    SSI.Store.update(:system, :authorized_keys, [], &Enum.uniq([String.trim(line) | &1]))
  end

  @impl true
  def init(_) do
    port = SSI.Config.integer("ssh.port", 22)

    if port == 0 or (not SSI.Sys.target?() and not Application.get_env(:ssi, :ssh, false)) do
      :ignore
    else
      send(self(), {:start, port})
      {:ok, %{daemon: nil}}
    end
  end

  @impl true
  def handle_info({:start, port}, state) do
    password = SSI.Config.get("ssh.password")

    opts =
      [
        key_cb: {SSI.SSH.Keys, []},
        shell: &shell/2,
        exec: :disabled,
        id_string: ~c"ElixirSSI",
        parallel_login: true,
        auth_methods: if(password, do: ~c"publickey,password", else: ~c"publickey")
      ] ++ if(password, do: [pwdfun: fn _user, pass -> to_string(pass) == password end], else: [])

    case :ssh.daemon(port, opts) do
      {:ok, daemon} ->
        Logger.info("ssh: listening on port #{port}")
        {:noreply, %{state | daemon: daemon}}

      {:error, reason} ->
        Logger.error("ssh: cannot listen on #{port}: #{inspect(reason)}")
        Process.send_after(self(), {:start, port}, 5_000)
        {:noreply, state}
    end
  end

  defp dot_iex, do: if(File.exists?("/root/.iex.exs"), do: "/root/.iex.exs", else: "")

  defp shell(_user, _peer) do
    spawn(fn ->
      IO.puts(SSI.Shell.motd())
      IEx.Server.run(dot_iex: dot_iex(), register: false, prefix: "ssh")
    end)
  end
end

defmodule SSI.SSH.Keys do
  @moduledoc "SSH key callbacks backed by the replicated store and /boot."
  @behaviour :ssh_server_key_api

  @impl true
  def host_key(:"ssh-ed25519", _opts), do: {:ok, cluster_host_key()}
  def host_key(_alg, _opts), do: {:error, :unsupported}

  @impl true
  def is_auth_key(key, _user, _opts) do
    Enum.any?(authorized(), fn {k, _attrs} -> k == key end)
  end

  defp cluster_host_key do
    case SSI.Store.get(:system, :ssh_host_key) do
      nil ->
        key = :public_key.generate_key({:namedCurve, :ed25519})
        SSI.Store.put_sync(:system, :ssh_host_key, key)
        # Concurrent first boots may race; the replicated value wins everywhere.
        SSI.Store.get(:system, :ssh_host_key)

      key ->
        key
    end
  end

  defp authorized do
    from_boot =
      case File.read("/boot/authorized_keys") do
        {:ok, text} -> [text]
        _ -> []
      end

    (from_boot ++ SSI.Store.get(:system, :authorized_keys, []))
    |> Enum.flat_map(fn text ->
      try do
        :ssh_file.decode(text, :auth_keys)
      rescue
        _ -> []
      end
    end)
  end
end
