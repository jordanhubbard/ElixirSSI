defmodule SSI.Cluster.Distribution do
  @moduledoc """
  Starts BEAM distribution once the network has a cluster address.

  On the target the node is named `ssi@<cluster-ip>`, listens on the fixed
  port from `SSI.Cluster.Epmd`, binds only to the cluster interface, and uses
  the cookie derived from the cluster secret. Distribution traffic is TLS 1.3
  with mutual certificate verification (`SSI.Cluster.TLS`). A node with no network at all
  still boots, as a one-node cluster named `ssi@127.0.0.1`.
  """
  use GenServer, restart: :transient
  require Logger

  def start_link(_), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @impl true
  def init(_) do
    if SSI.Sys.target?() and node() == :nonode@nohost do
      ip =
        case SSI.Net.cluster_address(30_000) do
          {:ok, ip} -> ip
        end

      start(ip)
    else
      if node() != :nonode@nohost, do: Node.set_cookie(SSI.Cluster.Identity.cookie())
    end

    :ignore
  catch
    :exit, _ ->
      Logger.warning("cluster: no network address; running as a single node")
      start({127, 0, 0, 1})
      :ignore
  end

  defp start(ip) do
    :ok = SSI.Cluster.TLS.install()
    Application.put_env(:kernel, :inet_dist_use_interface, ip)
    name = :"ssi@#{SSI.Net.Addr.to_string(ip)}"

    case :net_kernel.start(name, %{name_domain: :longnames}) do
      {:ok, _} ->
        Node.set_cookie(SSI.Cluster.Identity.cookie())
        Logger.info("cluster: this node is #{name}")

      {:error, reason} ->
        Logger.error("cluster: distribution failed: #{inspect(reason)}")
    end
  end
end
