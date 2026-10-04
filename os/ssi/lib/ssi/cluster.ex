defmodule SSI.Cluster do
  @moduledoc """
  Cluster membership: the set of machines that together form the system.

  Any connected node running ElixirSSI is a member; BEAM distribution keeps
  the mesh fully connected, so "connected" and "member" coincide. Each node
  describes its hardware once (`node_info/0`); the descriptions of all
  members are cached locally so that aggregate views such as `summary/0` cost
  no network round trips.
  """
  use GenServer
  require Logger

  @table :ssi_members

  def start_link(_), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @doc "All members, sorted, including this node."
  def members, do: Enum.sort([node() | Node.list()])

  @doc "Other members."
  def peers, do: Node.list()

  def size, do: length(members())

  @doc "Cached hardware description of a member."
  def info(node \\ node()) do
    case :ets.lookup(@table, node) do
      [{^node, info}] -> info
      [] -> fetch_info(node)
    end
  end

  @doc "Descriptions of every member."
  def infos, do: Enum.map(members(), &info/1)

  @doc "Descriptions of the members already cached here (no network calls)."
  def cached_infos do
    for n <- members(), [{^n, info}] <- [:ets.lookup(@table, n)], do: info
  end

  @doc "The aggregate machine: total cores, memory and the members behind them."
  def summary do
    infos = infos()

    %{
      cluster: SSI.Cluster.Identity.cluster(),
      nodes: length(infos),
      cores: infos |> Enum.map(& &1.cores) |> Enum.sum(),
      schedulers: infos |> Enum.map(& &1.schedulers) |> Enum.sum(),
      memory: infos |> Enum.map(& &1.memory) |> Enum.sum(),
      members: Enum.map(infos, & &1.hostname)
    }
  end

  @doc "Short human name of a member (its host name)."
  def hostname(node) do
    case info(node) do
      %{hostname: h} -> h
      _ -> node |> to_string() |> String.split("@") |> List.last()
    end
  end

  @doc "This node's hardware and software description."
  def node_info do
    %{
      node: node(),
      hostname: SSI.Boot.hostname(),
      ip: node() |> to_string() |> String.split("@") |> List.last(),
      cores: :erlang.system_info(:logical_processors_available) |> cores(),
      schedulers: :erlang.system_info(:schedulers_online),
      memory: SSI.Load.total_memory(),
      model: model(),
      arch: :erlang.system_info(:system_architecture) |> to_string(),
      otp: :erlang.system_info(:otp_release) |> to_string(),
      elixir: System.version(),
      kernel: kernel_release(),
      persistent: SSI.Boot.persistent?(),
      booted_at: System.os_time(:second) - div(:erlang.statistics(:wall_clock) |> elem(0), 1000),
      boot_id: SSI.Status.BootRecord.boot_id(),
      previous_boot: SSI.Status.BootRecord.previous(),
      addresses: addresses(),
      web_port: SSI.Web.port(),
      web_tls_port: SSI.Web.tls_port()
    }
  end

  defp addresses do
    for %{if: ifname, ip: ip} <- SSI.Net.addresses(), do: %{if: ifname, ip: SSI.Net.Addr.to_string(ip)}
  catch
    :exit, _ -> []
  end

  defp cores(:unknown), do: :erlang.system_info(:logical_processors)
  defp cores(n), do: n

  defp model do
    case File.read("/proc/device-tree/model") do
      {:ok, m} -> String.trim_trailing(m, <<0>>)
      _ -> if SSI.Sys.target?(), do: "virtual machine", else: "hosted"
    end
  end

  defp kernel_release do
    case File.read("/proc/sys/kernel/osrelease") do
      {:ok, r} -> String.trim(r)
      _ -> "unknown"
    end
  end

  defp fetch_info(node) do
    case :erpc.call(node, __MODULE__, :node_info, [], 5_000) do
      info when is_map(info) ->
        :ets.insert(@table, {node, info})
        info
    end
  catch
    _, _ -> %{node: node, hostname: hostname_of(node), cores: 0, schedulers: 0, memory: 0}
  end

  defp hostname_of(node), do: node |> to_string() |> String.split("@") |> List.last()

  # -- server -----------------------------------------------------------------

  @impl true
  def init(_) do
    :ets.new(@table, [:named_table, :public, read_concurrency: true])
    :ets.insert(@table, {node(), node_info()})
    :ok = :net_kernel.monitor_nodes(true, node_type: :visible)
    for n <- Node.list(), do: send(self(), {:nodeup, n, []})
    {:ok, %{}}
  end

  @impl true
  def handle_info({:nodeup, node, _}, state) do
    # Our own name may have changed when distribution started after init.
    :ets.insert(@table, {node(), node_info()})

    Task.start(fn ->
      # Complete the mesh: connect to everyone the new member knows, so all
      # members share one view of the membership as soon as possible.
      for peer <- :erpc.call(node, Node, :list, [], 5_000) -- [node() | Node.list()], do: Node.connect(peer)
      info = fetch_info(node)
      Logger.info("cluster: #{info.hostname} joined (#{node}); #{size()} nodes")
      SSI.Events.publish(:membership, {:ssi_membership, :up, node})
    end)

    {:noreply, state}
  end

  def handle_info({:nodedown, node, _}, state) do
    :ets.delete(@table, node)
    Logger.warning("cluster: #{node} left; #{size()} nodes")
    SSI.Events.publish(:membership, {:ssi_membership, :down, node})
    {:noreply, state}
  end
end
