defmodule SSI.QuorumTest do
  # Services under partition: only a group holding quorum of the roster runs them.
  use ExUnit.Case, async: false
  import SSI.TestCluster

  alias SSI.Cluster.Roster
  alias SSI.TestWork.Counter

  setup_all do
    peers = start_peers([:"ssi-q-a"])
    on_exit(fn -> stop_peers(peers) end)
    [{_, peer}] = peers
    eventually(fn -> SSI.Cluster.members() == Enum.sort([node(), peer]) end)
    # Both members enroll themselves.
    eventually(fn -> Enum.sort(Enum.map(Roster.all(), & &1.node)) == SSI.Cluster.members() end)
    %{peer: peer}
  end

  setup do
    on_exit(fn ->
      for id <- ["0-gone", "1-gone", "~gone", "~gone-2"], do: Roster.forget(id)
    end)
  end

  # A member the cluster has had that is not connected now (as if on the other
  # side of a partition, or powered off).
  defp absent(id), do: SSI.Store.put_sync(:roster, id, %{node: :"#{id}@10.9.9.9", hostname: id, since: 0})

  test "every member enrolls itself; a group counts its present members", %{peer: peer} do
    ids = Enum.map(Roster.all(), & &1.id)
    assert Atom.to_string(node()) in ids and Atom.to_string(peer) in ids
    # Two members: quorum is not required (services.partition = auto).
    assert %{quorum: true, policy: "available", absent: []} = Roster.quorum()
    refute Roster.quorum([node()]).policy == "quorum"

    # From three it is: two of three is a majority; two of four is a tie.
    absent("~gone")
    assert %{quorum: true, policy: "quorum", present: [_, _], absent: ["~gone"]} = Roster.quorum()
    absent("~gone-2")
    q = Roster.quorum()
    assert length(q.roster) == 4
    # The tie-breaker (lowest id) is present, so this half wins...
    assert q.tie_breaker == Enum.min(q.present) and q.quorum
    Roster.forget("~gone-2")

    # ...and loses when the lowest id is on the other side.
    absent("0-gone")
    assert %{quorum: false, tie_breaker: "0-gone"} = Roster.quorum()

    # A lone member of the same roster is a minority either way.
    refute Roster.quorum?([node()])
  end

  test "a group that loses quorum stops its services; regaining it restarts them", %{peer: peer} do
    :ok = SSI.Service.register(:q_counter, Counter, %{}, node: peer)
    on_exit(fn -> SSI.Service.unregister(:q_counter) end)
    eventually(fn -> where(:q_counter) == peer end)
    assert SSI.Service.call(:q_counter, :inc) == 1

    # Two absent members, one of them the tie-breaker: this group is fenced.
    absent("0-gone")
    absent("~gone")
    eventually(fn -> where(:q_counter) == nil end, 15_000)
    assert SSI.Service.owner(:q_counter) == nil
    assert :erpc.call(peer, SSI.Service, :owner, [:q_counter]) == nil
    assert %{quorum: %{quorum: false, absent: ["0-gone", "~gone"]}} = SSI.Status.snapshot().system

    # Both members record it, and why the service stopped.
    eventually(fn ->
      events = SSI.Status.Journal.recent()
      Enum.any?(events, &(&1.kind == "quorum" and &1.detail.held == false)) and
        Enum.any?(events, &(&1.kind == "service_stopped" and &1.subject == "q_counter" and &1.detail.reason == "quorum lost"))
    end)

    # The tie-breaker retires for good: the operator forgets it, and the
    # service comes back with its checkpointed state.
    assert {:ok, ["0-gone"]} = Roster.forget("0-gone")
    eventually(fn -> where(:q_counter) == peer end, 15_000)
    assert SSI.Service.call(:q_counter, :inc) == 2
    eventually(fn -> Enum.any?(SSI.Status.Journal.recent(), &(&1.kind == "quorum" and &1.detail.held)) end)
  end

  test "a current member cannot be forgotten", %{peer: peer} do
    assert {:error, _} = Roster.forget(Atom.to_string(peer))
    assert Enum.any?(Roster.all(), &(&1.node == peer))
  end

  test "services.partition chooses the policy" do
    absent("0-gone")
    absent("1-gone")
    refute Roster.quorum?()

    before = Application.get_env(:ssi, :config, %{})

    set = fn policy ->
      Application.put_env(:ssi, :config, Map.put(before, "services.partition", policy))
      SSI.Config.load()
    end

    on_exit(fn ->
      Application.put_env(:ssi, :config, before)
      SSI.Config.load()
    end)

    set.("available")
    assert %{quorum: true, policy: "available"} = Roster.quorum()

    # quorum applies even to two members: losing the tie-breaker stops services.
    set.("quorum")
    Roster.forget("0-gone")
    Roster.forget("1-gone")
    assert %{policy: "quorum", quorum: true} = Roster.quorum()
    lone = Roster.quorum([node()])
    assert lone.policy == "quorum" and lone.quorum == (Atom.to_string(node()) == lone.tie_breaker)
  end

  defp where(name) do
    case SSI.Service.whereis(name) do
      pid when is_pid(pid) -> node(pid)
      nil -> nil
    end
  end
end
