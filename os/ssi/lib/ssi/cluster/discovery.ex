defmodule SSI.Cluster.Discovery do
  @moduledoc """
  Zero-configuration cluster formation.

  Every node multicasts a signed beacon on the cluster interface every two
  seconds (and unicasts it to any configured `peers`). A node that hears a
  valid beacon for its cluster from a node it is not yet connected to calls
  `Node.connect/1`; BEAM distribution then makes the mesh transitive. Adding a
  Raspberry Pi to the cluster is therefore: plug it into the switch, power it
  on.

  Beacons are HMAC-SHA256 signed with a key derived from the cluster secret
  and are decoded with `binary_to_term(_, [:safe])` only after verification.
  """
  use GenServer
  require Logger
  alias SSI.Cluster.Identity

  @interval 2_000

  def start_link(_), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @doc "Nodes heard from, with the monotonic time of their last beacon."
  def heard, do: GenServer.call(__MODULE__, :heard)

  @impl true
  def init(_) do
    if node() == :nonode@nohost or not SSI.Sys.target?() and not Application.get_env(:ssi, :discovery, false) do
      :ignore
    else
      {:ok, ip} = node_ip()
      {:ok, group} = SSI.Net.Addr.parse(SSI.Config.get("discovery.group"))
      port = SSI.Config.integer("discovery.port", 45892)

      {:ok, sock} =
        :gen_udp.open(port, [
          :binary,
          active: true,
          reuseaddr: true,
          ip: {0, 0, 0, 0},
          add_membership: {group, ip},
          multicast_if: ip,
          multicast_ttl: 1,
          multicast_loop: false
        ])

      send(self(), :beacon)
      {:ok, %{sock: sock, group: group, port: port, heard: %{}}}
    end
  end

  defp node_ip do
    node() |> to_string() |> String.split("@") |> List.last() |> SSI.Net.Addr.parse()
  end

  @impl true
  def handle_call(:heard, _from, state), do: {:reply, state.heard, state}

  @impl true
  def handle_info(:beacon, state) do
    packet =
      %{v: 1, cluster: Identity.cluster(), node: Atom.to_string(node()), host: SSI.Boot.hostname()}
      |> :erlang.term_to_binary()
      |> Identity.sign()

    :gen_udp.send(state.sock, state.group, state.port, packet)

    for peer <- SSI.Config.peers(), {:ok, ip} <- [SSI.Net.Addr.parse(peer)] do
      :gen_udp.send(state.sock, ip, state.port, packet)
    end

    Process.send_after(self(), :beacon, @interval)
    {:noreply, state}
  end

  def handle_info({:udp, _sock, _ip, _port, packet}, state) do
    with {:ok, payload} <- Identity.verify(packet),
         %{v: 1, cluster: cluster, node: name} when is_binary(name) <- safe_decode(payload),
         true <- cluster == Identity.cluster() and String.starts_with?(name, "ssi@"),
         # The signature is verified, so creating this atom is not attacker-driven.
         peer = String.to_atom(name),
         true <- peer != node() do
      unless peer in Node.list() do
        Logger.info("discovery: found #{peer}")
        Task.start(fn -> Node.connect(peer) end)
      end

      {:noreply, %{state | heard: Map.put(state.heard, peer, System.monotonic_time(:millisecond))}}
    else
      _ -> {:noreply, state}
    end
  end

  defp safe_decode(payload) do
    :erlang.binary_to_term(payload, [:safe])
  rescue
    _ -> nil
  end
end
