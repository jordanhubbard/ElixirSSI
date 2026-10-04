defmodule SSI.ClusterTest do
  # Real multi-node tests: each peer is a separate BEAM running the full SSI
  # application, connected by Erlang distribution exactly as Pis are.
  use ExUnit.Case, async: false
  import SSI.TestCluster

  alias SSI.TestWork.Counter

  setup_all do
    peers = start_peers([:"ssi-a", :"ssi-b"])
    on_exit(fn -> stop_peers(peers) end)
    nodes = Enum.map(peers, &elem(&1, 1))
    all = Enum.sort([node() | nodes])
    eventually(fn -> Enum.all?(all, &(:erpc.call(&1, SSI.Cluster, :members, []) == all)) end)
    %{peers: peers, nodes: nodes}
  end

  test "membership and the aggregate machine", %{nodes: [a, b]} do
    eventually(fn -> length(:erpc.call(a, SSI.Cluster, :members, [])) == 3 end)
    summary = :erpc.call(b, SSI.Cluster, :summary, [])
    assert summary.nodes == 3
    assert summary.cores == 3 * :erlang.system_info(:logical_processors)
    eventually(fn -> length(SSI.Load.cluster()) == 3 end)
  end

  test "replicated store converges and honours deletes", %{nodes: [a, b]} do
    :ok = :erpc.call(a, SSI.Store, :put, [:t, :k, 1])
    eventually(fn -> :erpc.call(b, SSI.Store, :get, [:t, :k]) == 1 end)
    :ok = :erpc.call(b, SSI.Store, :put, [:t, :k, 2])
    eventually(fn -> :erpc.call(a, SSI.Store, :get, [:t, :k]) == 2 and SSI.Store.get(:t, :k) == 2 end)
    :ok = SSI.Store.delete(:t, :k)
    eventually(fn -> :erpc.call(a, SSI.Store, :get, [:t, :k, :gone]) == :gone end)
  end

  test "a partitioned node catches up by anti-entropy", %{nodes: [a, b]} do
    # Writes that bypass replication (as if sent while partitioned) still converge.
    :ok = :erpc.call(a, GenServer, :call, [SSI.Store, {:merge, [{{:p, :x}, :late, {System.os_time(:millisecond), 0, a}}]}])
    refute :erpc.call(b, SSI.Store, :get, [:p, :x])
    :ok = :erpc.call(b, SSI.Store, :sync, [])
    assert :erpc.call(b, SSI.Store, :get, [:p, :x]) == :late
  end

  test "one filesystem namespace from every node", %{nodes: [a, b]} do
    :ok = :erpc.call(a, SSI.FS, :mkdir_p, ["/home/ada"])
    big = :crypto.strong_rand_bytes(2_500_000)
    :ok = :erpc.call(a, SSI.FS, :write, ["/home/ada/data.bin", big])

    eventually(fn -> match?({:ok, %{size: 2_500_000}}, :erpc.call(b, SSI.FS, :stat, ["/home/ada/data.bin"])) end)
    assert {:ok, ^big} = :erpc.call(b, SSI.FS, :read, ["/home/ada/data.bin"])
    assert {:ok, ^big} = SSI.FS.read("/home/ada/data.bin")

    :ok = :erpc.call(b, SSI.FS, :append, ["/home/ada/log", "one\n"])
    eventually(fn -> SSI.FS.exists?("/home/ada/log") end)
    :ok = SSI.FS.append("/home/ada/log", "two\n")
    eventually(fn -> :erpc.call(a, SSI.FS, :read, ["/home/ada/log"]) == {:ok, "one\ntwo\n"} end)

    :ok = SSI.FS.rename("/home/ada", "/home/lovelace")
    eventually(fn -> :erpc.call(a, SSI.FS, :exists?, ["/home/lovelace/log"]) end)
    refute SSI.FS.exists?("/home/ada/log")

    {:ok, entries} = :erpc.call(b, SSI.FS, :ls, ["/"])
    assert Enum.any?(entries, &(&1.name == "proc")) and Enum.any?(entries, &(&1.name == "home"))
    assert {:ok, text} = :erpc.call(a, SSI.FS, :read, ["/proc/cluster"])
    assert text =~ "nodes:      3"
    assert {:error, :enotempty} = SSI.FS.rm("/home/lovelace")
    :ok = SSI.FS.rm_rf("/home/lovelace")
    eventually(fn -> not :erpc.call(b, SSI.FS, :exists?, ["/home/lovelace"]) end)
  end

  test "file blobs are replicated and repaired", %{nodes: nodes} do
    data = :crypto.strong_rand_bytes(1000)
    {:ok, h} = SSI.Blob.put(data)
    holders = SSI.Blob.holders(h)
    assert length(holders) == 2
    for n <- holders, do: assert(:erpc.call(n, SSI.Blob, :local_has?, [h]))

    # Lose one copy; repair restores it from the survivor.
    [first | _] = holders
    :erpc.call(first, File, :rm, [Path.join([:erpc.call(first, SSI.Boot, :data_dir, []), "blobs", binary_part(h, 0, 2), h])])
    refute :erpc.call(first, SSI.Blob, :local_has?, [h])
    for n <- [node() | nodes], do: :erpc.call(n, SSI.Blob, :repair, [])
    assert :erpc.call(first, SSI.Blob, :local_has?, [h])
    for n <- [node() | nodes], do: assert({:ok, ^data} = :erpc.call(n, SSI.Blob, :get, [h]))
  end

  test "the process table spans the cluster", %{nodes: [a, _b]} do
    ps = SSI.Proc.ps()
    assert Enum.map(ps, & &1.node) |> Enum.uniq() |> length() == 3
    store = Enum.find(ps, &(&1.node == a and &1.name == "SSI.Store"))
    assert store.id =~ ":<0."
    assert SSI.Proc.pid(store.id) == :erpc.call(a, Process, :whereis, [SSI.Store])
  end

  test "pmap uses every node and survives a node failure", %{nodes: [a, _b]} do
    result = SSI.Sched.pmap(1..40, &SSI.TestWork.square_where/1)
    assert Enum.map(result, &elem(&1, 0)) == Enum.map(1..40, &(&1 * &1))
    assert result |> Enum.map(&elem(&1, 1)) |> Enum.uniq() |> length() == 3

    # Items running on a node that dies are re-run elsewhere.
    {:ok, extra_pid, extra} = start_extra(:"ssi-c")
    eventually(fn -> extra in SSI.Cluster.members() end)
    parent = self()

    task =
      Task.async(fn ->
        SSI.Sched.each(1..60, &SSI.TestWork.slow/1, [], fn i, n, v -> send(parent, {:done, i, n, v}) end)
      end)

    eventually(fn -> receive do {:done, _, ^extra, _} -> true after 0 -> false end end, 20_000)
    :peer.stop(extra_pid)
    stats = Task.await(task, 30_000)
    assert Enum.sum(Map.values(stats.nodes)) == 60
    refute a == extra
  end

  test "services fail over and migrate with their state", %{nodes: [a, b]} do
    {extra_pid, extra} = with {:ok, p, n} <- start_extra(:"ssi-d"), do: {p, n}
    eventually(fn -> extra in SSI.Cluster.members() end)

    :ok = SSI.Service.register(:counter, Counter, %{}, node: extra)
    eventually(fn -> SSI.Service.whereis(:counter) && node(SSI.Service.whereis(:counter)) == extra end)
    assert SSI.Service.call(:counter, :inc) == 1
    assert SSI.Service.call(:counter, :inc) == 2

    # Migrate: the checkpoint written on stop is restored by the new owner.
    :ok = SSI.Service.move(:counter, a)
    eventually(fn -> pid = SSI.Service.whereis(:counter); pid && node(pid) == a end)
    assert SSI.Service.call(:counter, :inc) == 3

    # Pin to the extra node again, then kill that node: the service fails
    # over to a survivor (state up to the last checkpoint survives).
    :ok = SSI.Service.move(:counter, extra)
    eventually(fn -> pid = SSI.Service.whereis(:counter); pid && node(pid) == extra end)
    :peer.stop(extra_pid)
    eventually(fn -> pid = SSI.Service.whereis(:counter); pid && node(pid) in [node(), a, b] end, 20_000)
    assert SSI.Service.call(:counter, :inc) == 4
    SSI.Service.unregister(:counter)
    eventually(fn -> SSI.Service.whereis(:counter) == nil end)
  end

  defp start_extra(name) do
    [{pid, node}] = start_peers([name])
    eventually(fn -> Enum.all?(SSI.Cluster.members(), &(node in :erpc.call(&1, SSI.Cluster, :members, []))) end)
    {:ok, pid, node}
  end
end
