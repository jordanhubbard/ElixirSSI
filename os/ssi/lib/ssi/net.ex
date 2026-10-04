defmodule SSI.Net do
  @moduledoc """
  Network manager.

  Every Ethernet interface gets a policy from configuration (`net.IFNAME`), a
  comma-separated list of methods tried in order:

    * `dhcp` — lease from a DHCP server (`SSI.Net.DHCP`), renewed at T1;
    * `linklocal` — a stable 169.254/16 address derived from the MAC address,
      which lets a switch-only cluster come up with no infrastructure at all;
    * `static:10.0.0.5/24` or `static:10.0.0.5/24@10.0.0.1` (with gateway);
    * `off`.

  The default is `dhcp,linklocal`. The *cluster address* — the address the
  node's distribution listener and discovery beacons use — comes from the
  `cluster_if` interface, or else the first interface that came up.
  """
  use GenServer
  require Logger
  alias SSI.Net.{Addr, DHCP, Link}

  def start_link(_), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @doc "Configured IPv4 addresses: `[%{if:, ip:, prefix:, method:, gateway:}]`."
  def addresses, do: GenServer.call(__MODULE__, :addresses)

  @doc "Block until the cluster address is known (or `timeout` elapses)."
  def cluster_address(timeout \\ 30_000), do: GenServer.call(__MODULE__, :cluster_address, timeout)

  @doc "Interface statistics for every link."
  def links do
    for name <- Link.all() do
      %{name: name, mac: Link.mac(name), carrier: Link.carrier?(name), speed: Link.speed(name), stats: Link.stats(name)}
    end
  end

  # -- server -----------------------------------------------------------------

  @impl true
  def init(_) do
    state = %{addresses: [], waiters: [], leases: %{}}

    if SSI.Sys.target?() do
      SSI.Sys.link("lo", true)
      SSI.Sys.set_ipv4("lo", {127, 0, 0, 1}, 8)
      send(self(), :configure)
      {:ok, state}
    else
      {:ok, %{state | addresses: hosted_addresses()}}
    end
  end

  @impl true
  def handle_call(:addresses, _from, state), do: {:reply, state.addresses, state}

  def handle_call(:cluster_address, from, state) do
    case pick_cluster(state.addresses) do
      nil -> {:noreply, %{state | waiters: [from | state.waiters]}}
      ip -> {:reply, {:ok, ip}, state}
    end
  end

  @impl true
  def handle_info(:configure, state) do
    # Configure interfaces concurrently: a DHCP timeout on one port must not
    # delay a link-local cluster port.
    parent = self()

    for ifname <- Link.ethernet() do
      Task.start(fn -> send(parent, {:configured, ifname, configure(ifname)}) end)
    end

    {:noreply, state}
  end

  def handle_info({:configured, ifname, {:ok, entry, lease}}, state) do
    Logger.info("net: #{ifname} #{Addr.to_string(entry.ip)}/#{entry.prefix} via #{entry.method}")
    addresses = Enum.reject(state.addresses, &(&1.if == ifname)) ++ [entry]
    if lease, do: Process.send_after(self(), {:renew, ifname}, div(lease.lease, 2) * 1000)
    write_resolv(lease)

    state = %{state | addresses: addresses, leases: Map.put(state.leases, ifname, lease)}

    case pick_cluster(addresses) do
      nil ->
        {:noreply, state}

      ip ->
        Enum.each(state.waiters, &GenServer.reply(&1, {:ok, ip}))
        {:noreply, %{state | waiters: []}}
    end
  end

  def handle_info({:configured, ifname, {:error, reason}}, state) do
    Logger.warning("net: #{ifname} not configured: #{inspect(reason)}")
    {:noreply, state}
  end

  def handle_info({:renew, ifname}, state) do
    lease = state.leases[ifname]
    parent = self()

    Task.start(fn ->
      case DHCP.renew(ifname, lease, mac: Link.mac(ifname), hostname: SSI.Boot.hostname()) do
        {:ok, fresh} when fresh.ip == lease.ip ->
          Process.send_after(parent, {:renew, ifname}, div(fresh.lease, 2) * 1000)

        _ ->
          # Keep the address: changing it would rename this node in the
          # cluster. Retry later; the server normally re-issues the same lease.
          Process.send_after(parent, {:renew, ifname}, 60_000)
      end
    end)

    {:noreply, state}
  end

  # -- policy -----------------------------------------------------------------

  defp configure(ifname) do
    SSI.Sys.link(ifname, true)
    Link.await_carrier(ifname, 3_000)

    ifname
    |> SSI.Config.net_policy()
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reduce_while({:error, :no_method}, fn method, _ ->
      case apply_method(ifname, method) do
        {:ok, _, _} = ok -> {:halt, ok}
        error -> {:cont, error}
      end
    end)
  end

  defp apply_method(_ifname, "off"), do: {:error, :disabled}

  defp apply_method(ifname, "dhcp") do
    with {:ok, lease} <- DHCP.acquire(ifname, mac: Link.mac(ifname), hostname: SSI.Boot.hostname()),
         :ok <- SSI.Sys.set_ipv4(ifname, lease.ip, lease.prefix) do
      if lease.router, do: SSI.Sys.default_route(ifname, lease.router)
      {:ok, %{if: ifname, ip: lease.ip, prefix: lease.prefix, method: :dhcp, gateway: lease.router}, lease}
    end
  end

  defp apply_method(ifname, "linklocal") do
    ip = Addr.link_local(Link.mac(ifname))

    with :ok <- SSI.Sys.set_ipv4(ifname, ip, 16) do
      {:ok, %{if: ifname, ip: ip, prefix: 16, method: :linklocal, gateway: nil}, nil}
    end
  end

  defp apply_method(ifname, "static:" <> spec) do
    {cidr, gw} =
      case String.split(spec, "@") do
        [cidr, gw] -> {cidr, Addr.parse(gw)}
        [cidr] -> {cidr, nil}
      end

    with {:ok, ip, prefix} <- Addr.parse_cidr(cidr),
         :ok <- SSI.Sys.set_ipv4(ifname, ip, prefix) do
      gateway =
        case gw do
          {:ok, g} -> SSI.Sys.default_route(ifname, g) && g
          _ -> nil
        end

      {:ok, %{if: ifname, ip: ip, prefix: prefix, method: :static, gateway: gateway}, nil}
    end
  end

  defp apply_method(_ifname, other), do: {:error, {:unknown_method, other}}

  defp pick_cluster([]), do: nil

  defp pick_cluster(addresses) do
    case SSI.Config.get("cluster_if") do
      nil -> hd(addresses).ip
      ifname -> Enum.find_value(addresses, &(&1.if == ifname && &1.ip))
    end
  end

  defp write_resolv(nil), do: :ok

  defp write_resolv(%DHCP{dns: dns}) when dns != [] do
    File.write("/etc/resolv.conf", Enum.map_join(dns, "", &"nameserver #{Addr.to_string(&1)}\n"))
    :inet_db.set_lookup([:file, :dns])
    Enum.each(dns, &:inet_db.add_ns/1)
  end

  defp write_resolv(_), do: :ok

  defp hosted_addresses do
    [%{if: "lo", ip: {127, 0, 0, 1}, prefix: 8, method: :hosted, gateway: nil}]
  end
end
