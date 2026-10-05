defmodule SSI.Cluster.Roster do
  @moduledoc """
  The members the cluster has had, and whether this side of a partition
  holds quorum.

  Membership is the connected set, so a member cut off from the rest cannot
  tell from membership alone whether it is in the larger or the smaller
  group. The roster remembers every member that has joined, in the
  replicated store, keyed by a stable member id: the host name on hardware
  (configured, or derived from the Ethernet address), the node name in
  hosted mode, where every node shares the host's name. Node names follow
  addresses, so each entry also records the node name its member last used;
  every member keeps its own entry current.

  A group of connected members holds quorum when it has more than half of
  the roster, or exactly half including the roster's lowest member id, so
  that of two equal halves exactly one wins. Services run only where there
  is quorum (`SSI.Service`); everything else stays available on both sides.

  A member that is retired for good leaves the roster only when an operator
  says so (`forget/1`); until then it counts as absent.

  Configuration `services.partition` chooses the policy: `quorum` as above;
  `available`, every group counts as holding quorum and each side of a
  partition runs its own instances; `auto` (the default), `quorum` once the
  roster has three members and `available` before. Two members cannot tell
  a partition from a failure, and quorum would only turn the tie-breaking
  member's failure into the loss of every service.
  """

  @table :roster

  @doc "This member's roster id."
  def self_id, do: if(SSI.Sys.target?(), do: SSI.Boot.hostname(), else: Atom.to_string(node()))

  @doc "Record this member, or update the node name it uses. Cheap when nothing changed."
  def enroll do
    id = self_id()

    case SSI.Store.get(@table, id) do
      %{node: n} when n == node() -> :ok
      _ -> SSI.Store.put(@table, id, %{node: node(), hostname: SSI.Boot.hostname(), since: System.os_time(:millisecond)})
    end
  end

  @doc "The roster: `[%{id:, node:, hostname:, since:}]`, sorted by id."
  def all do
    for {id, e} <- SSI.Store.all(@table) |> Enum.sort(), do: Map.put(e, :id, id)
  end

  @doc """
  Quorum as seen by a group of connected `members`:
  `%{policy:, quorum:, roster:, present:, absent:, tie_breaker:}` (ids).
  """
  def quorum(members \\ SSI.Cluster.members()) do
    roster = all()
    # A member that has not been recorded yet (it has just joined) still counts.
    present =
      MapSet.new(for(e <- roster, e.node in members, do: e.id))
      |> MapSet.union(if(node() in members, do: MapSet.new([self_id()]), else: MapSet.new()))

    ids = Enum.uniq(Enum.map(roster, & &1.id) ++ MapSet.to_list(present)) |> Enum.sort()
    tie_breaker = List.first(ids)
    have = MapSet.size(present)
    policy = policy(length(ids))

    held =
      policy == "available" or 2 * have > length(ids) or
        (2 * have == length(ids) and MapSet.member?(present, tie_breaker))

    %{
      policy: policy,
      quorum: held,
      roster: ids,
      present: Enum.sort(MapSet.to_list(present)),
      absent: Enum.reject(ids, &MapSet.member?(present, &1)),
      tie_breaker: tie_breaker
    }
  end

  @doc "Whether `members` hold quorum."
  def quorum?(members \\ SSI.Cluster.members()), do: quorum(members).quorum

  @doc """
  Remove a retired member (by id or host name) from the roster. Refused
  while it is connected. Returns the ids removed.
  """
  def forget(id_or_host) do
    connected = SSI.Cluster.members()
    matches = for e <- all(), e.id == id_or_host or e.hostname == id_or_host, do: e

    case Enum.filter(matches, &(&1.node in connected)) do
      [] ->
        Enum.each(matches, &SSI.Store.delete(@table, &1.id))
        {:ok, Enum.map(matches, & &1.id)}

      present ->
        {:error, "#{Enum.map_join(present, ", ", & &1.id)} is a current member"}
    end
  end

  @doc false
  def table, do: @table

  # The policy in effect for a roster of `size` members.
  defp policy(size) do
    case SSI.Config.get("services.partition", "auto") do
      "available" -> "available"
      "quorum" -> "quorum"
      _ -> if size >= 3, do: "quorum", else: "available"
    end
  end
end
