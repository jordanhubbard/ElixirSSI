defmodule SSI.StatusTest do
  use ExUnit.Case, async: false
  import SSI.TestCluster

  alias SSI.Status.BootRecord
  alias SSI.TestWork.Counter

  describe "previous-boot record" do
    setup do
      saved = :persistent_term.get({BootRecord, :boot}, nil)
      dir = Path.join(System.tmp_dir!(), "ssi-bootrec-#{System.unique_integer([:positive])}")
      on_exit(fn ->
        File.rm_rf(dir)
        if saved, do: :persistent_term.put({BootRecord, :boot}, saved)
      end)

      %{dir: dir}
    end

    test "first boot, unclean end, clean end", %{dir: dir} do
      assert BootRecord.start(dir, true) == %{"ended" => "unknown"}
      first = BootRecord.boot_id()
      :ok = BootRecord.alive()

      # No ended mark: the boot ended without warning.
      prev = BootRecord.start(dir, true)
      assert prev["ended"] == "unclean"
      assert is_integer(prev["alive_at"])
      assert BootRecord.boot_id() != first

      :ok = BootRecord.ended(:restart)
      assert %{"ended" => "clean", "action" => "restart"} = BootRecord.start(dir, true)
    end

    test "volatile storage has no record", %{dir: dir} do
      BootRecord.start(dir, true)
      assert BootRecord.start(dir, false) == %{"ended" => "unknown"}
    end

    test "a damaged record reads as unknown", %{dir: dir} do
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "boot.json"), "{not json")
      assert BootRecord.start(dir, true) == %{"ended" => "unknown"}
    end
  end

  describe "snapshot and journal across members" do
    setup do
      peers = start_peers([:"ssi-st-a", :"ssi-st-b"])
      on_exit(fn -> stop_peers(peers) end)
      nodes = Enum.map(peers, &elem(&1, 1))
      all = Enum.sort([node() | nodes])
      eventually(fn -> Enum.all?(all, &(:erpc.call(&1, SSI.Cluster, :members, []) == all)) end)
      eventually(fn -> length(SSI.Load.cluster()) == 3 end)
      %{peers: peers, nodes: nodes}
    end

    test "the system as one machine and as its members", %{nodes: nodes} do
      snap = SSI.Status.snapshot()
      assert snap.schema == "elixirssi-status/1"
      assert snap.observer.node == node()
      assert snap.system.members == 3
      assert snap.system.cores == 3 * :erlang.system_info(:logical_processors)
      assert Enum.map(snap.members, & &1.node) == Enum.sort([node() | nodes])
      assert Enum.all?(snap.members, &(&1.load && is_list(&1.load.history)))
      assert Enum.all?(snap.members, &is_binary(&1.boot_id))

      # The same view from every member, as JSON.
      decoded = :erpc.call(hd(nodes), SSI.Status, :json, []) |> JSON.decode!()
      assert decoded["system"]["members"] == 3
      assert length(decoded["members"]) == 3
      assert is_list(decoded["journal"])
      refute Map.has_key?(SSI.Status.snapshot(journal: false), :journal)
    end

    test "a failover is journalled with how long the service was unavailable", %{peers: peers, nodes: [a, b]} do
      :ok = SSI.Service.register(:status_counter, Counter, %{}, node: b)
      eventually(fn -> match?(%{running: true, node: ^b}, service(:status_counter)) end)
      assert Enum.any?(SSI.Status.snapshot().members, &(&1.node == b and "status_counter" in &1.services))

      # The service-started event originated on b reaches every member.
      eventually(fn -> journalled?(a, "service_started", "status_counter") end)

      {pid, ^b} = Enum.find(peers, &(elem(&1, 1) == b))
      :peer.stop(pid)

      eventually(fn -> match?(%{running: true}, service(:status_counter)) end, 30_000)

      eventually(fn ->
        Enum.any?(SSI.Status.Journal.recent(), fn e ->
          e.kind == "service_started" and e.subject == "status_counter" and e.detail[:how] == "failover" and
            is_integer(e.detail[:unavailable_ms])
        end)
      end)

      assert Enum.any?(SSI.Status.Journal.recent(), &(&1.kind == "member_left" and &1.detail.node == b))
      SSI.Service.unregister(:status_counter)
    end
  end

  test "event ids are unique and copies merge" do
    events = SSI.Status.Journal.recent()
    assert events == Enum.uniq_by(events, & &1.id)
    GenServer.cast(SSI.Status.Journal, {:events, events})
    assert SSI.Status.Journal.recent() |> length() == length(events)
  end

  defp service(name) do
    Enum.find(SSI.Status.snapshot().services, &(&1.name == SSI.Status.label(name)))
  end

  defp journalled?(node, kind, subject) do
    :erpc.call(node, SSI.Status.Journal, :recent, []) |> Enum.any?(&(&1.kind == kind and &1.subject == subject))
  end
end
