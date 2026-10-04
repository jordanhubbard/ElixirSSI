defmodule SSI.Store do
  @moduledoc """
  The cluster's replicated system state.

  Every node holds a full replica of a last-writer-wins map keyed by
  `{table, key}`. Each entry carries a hybrid logical clock timestamp
  `{wall_ms, counter, node}`; merging two replicas keeps the larger timestamp
  per key, which is commutative, associative and idempotent, so replicas that
  have seen the same writes hold the same state regardless of delivery order,
  duplication, or partitions in between (a state-based CRDT). Deletes write a
  tombstone so a stale replica cannot resurrect a removed key.

  Replication is push on write (`abcast` to every member), plus anti-entropy:
  every few seconds, and immediately when a node joins, a node exchanges
  per-bucket digests with a peer and both sides send the entries of the buckets
  that differ. A node that was down or partitioned therefore converges without
  a coordinator, a leader, or a quorum. The price is the CRDT price: concurrent
  writes to one key resolve to one of them, deterministically.

  Reads are local ETS lookups. Writes are serialised through this node's
  server, appended to `store.log` in the data directory, and replayed at boot.

  Tables in use by the system: `:fs` (file metadata), `:services`,
  `:service_state`, `:system`.
  """
  use GenServer
  require Logger

  @table :ssi_store
  @tomb :"$ssi_tombstone"
  @buckets 64
  @ae_interval 5_000

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  # -- reads (local) ----------------------------------------------------------

  def get(table, key, default \\ nil) do
    case :ets.lookup(@table, {table, key}) do
      [{_, @tomb, _}] -> default
      [{_, value, _}] -> value
      [] -> default
    end
  end

  @doc "All live `{key, value}` pairs of `table`."
  def all(table) do
    :ets.select(@table, [{{{table, :"$1"}, :"$2", :_}, [{:"=/=", :"$2", @tomb}], [{{:"$1", :"$2"}}]}])
  end

  def keys(table), do: all(table) |> Enum.map(&elem(&1, 0))

  @doc "Timestamp of the entry for `key` (including tombstones), or nil."
  def version(table, key) do
    case :ets.lookup(@table, {table, key}) do
      [{_, _, ts}] -> ts
      [] -> nil
    end
  end

  # -- writes -----------------------------------------------------------------

  @doc "Write a value; replicates asynchronously."
  def put(table, key, value), do: GenServer.call(__MODULE__, {:write, [{{table, key}, value}], false})

  @doc "Write several entries atomically on this node; replicates asynchronously."
  def put_many(table, pairs) do
    GenServer.call(__MODULE__, {:write, Enum.map(pairs, fn {k, v} -> {{table, k}, v} end), false})
  end

  @doc """
  Write a value and return once every reachable member has merged it. Used
  where a later reader on another node must observe the write (service
  checkpoints before a hand-off).
  """
  def put_sync(table, key, value, timeout \\ 5_000),
    do: GenServer.call(__MODULE__, {:write, [{{table, key}, value}], timeout}, timeout + 1_000)

  def delete(table, key), do: GenServer.call(__MODULE__, {:write, [{{table, key}, @tomb}], false})

  @doc "Read-modify-write on this node (last writer wins cluster-wide)."
  def update(table, key, default, fun), do: put(table, key, fun.(get(table, key, default)))

  def subscribe(table), do: SSI.Events.subscribe({:store, table})

  @doc false
  def merge_remote(entries), do: GenServer.call(__MODULE__, {:merge, entries})

  @doc "Force an anti-entropy round with every member (tests and `sync` command)."
  def sync do
    # Runs in the caller, so two nodes syncing at once cannot deadlock their
    # store servers; the servers only ever perform local merges.
    for peer <- Node.list() do
      try do
        merge_remote(:erpc.call(peer, __MODULE__, :digest_entries, [], 10_000))
        :erpc.call(peer, __MODULE__, :merge_remote, [digest_entries()], 10_000)
      catch
        _, _ -> :ok
      end
    end

    :ok
  end

  @doc "Statistics for /proc."
  def stats do
    %{entries: :ets.info(@table, :size), tombstones: :ets.select_count(@table, [{{:_, @tomb, :_}, [], [true]}])}
  end

  # -- server -----------------------------------------------------------------

  @impl true
  def init(opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    dir = Keyword.get(opts, :dir, SSI.Boot.data_dir())
    File.mkdir_p!(dir)
    path = Path.join(dir, "store.log")
    replayed = replay(path)
    {:ok, log} = :file.open(String.to_charlist(path), [:append, :raw, :binary])
    SSI.Events.subscribe(:membership)
    Process.send_after(self(), :anti_entropy, @ae_interval)
    if replayed > 0, do: Logger.info("store: replayed #{replayed} entries")
    {:ok, %{log: log, path: path, clock: {0, 0}, logged: replayed, dirty: false}}
  end

  @impl true
  def handle_call({:write, pairs, sync}, from, state) do
    {entries, state} =
      Enum.map_reduce(pairs, state, fn {tk, value}, st ->
        {ts, st} = tick(st)
        {{tk, value, ts}, st}
      end)

    state = apply_entries(entries, state)

    case sync do
      false ->
        GenServer.abcast(Node.list(), __MODULE__, {:delta, entries})
        {:reply, :ok, state}

      timeout ->
        # Reply from a helper so this server keeps serving merges meanwhile.
        peers = Node.list()

        Task.start(fn ->
          :erpc.multicall(peers, __MODULE__, :merge_remote, [entries], timeout)
          GenServer.reply(from, :ok)
        end)

        {:noreply, state}
    end
  end

  def handle_call({:merge, entries}, _from, state), do: {:reply, :ok, merge(entries, state)}

  @impl true
  def handle_cast({:delta, entries}, state), do: {:noreply, merge(entries, state)}

  def handle_cast({:ae_digest, peer, digest}, state) do
    differing = differing_buckets(digest)

    if differing != [] do
      GenServer.cast({__MODULE__, peer}, {:ae_entries, node(), bucket_entries(differing), differing})
    end

    {:noreply, state}
  end

  def handle_cast({:ae_entries, peer, entries, buckets}, state) do
    state = merge(entries, state)
    if peer != :none, do: GenServer.cast({__MODULE__, peer}, {:ae_entries, :none, bucket_entries(buckets), []})
    {:noreply, state}
  end

  @impl true
  def handle_info(:anti_entropy, state) do
    case Node.list() do
      [] -> :ok
      peers -> GenServer.cast({__MODULE__, Enum.random(peers)}, {:ae_digest, node(), digest()})
    end

    Process.send_after(self(), :anti_entropy, @ae_interval)
    {:noreply, maybe_compact(state)}
  end

  def handle_info({:ssi_membership, :up, peer}, state) do
    GenServer.cast({__MODULE__, peer}, {:ae_digest, node(), digest()})
    {:noreply, state}
  end

  def handle_info(_, state), do: {:noreply, state}

  # -- clock ------------------------------------------------------------------

  # Hybrid logical clock: wall time when it advances, a counter when it does
  # not, so timestamps are unique, monotonic per node, and close to real time.
  defp tick(%{clock: {l, c}} = state) do
    pt = System.os_time(:millisecond)
    {l2, c2} = if pt > l, do: {pt, 0}, else: {l, c + 1}
    {{l2, c2, node()}, %{state | clock: {l2, c2}}}
  end

  defp observe(%{clock: {l, c}} = state, {rl, rc, _}) do
    pt = System.os_time(:millisecond)
    l2 = Enum.max([l, rl, pt])

    c2 =
      cond do
        l2 == l and l2 == rl -> max(c, rc) + 1
        l2 == l -> c + 1
        l2 == rl -> rc + 1
        true -> 0
      end

    %{state | clock: {l2, c2}}
  end

  # -- merge ------------------------------------------------------------------

  defp merge(entries, state) do
    fresh =
      Enum.filter(entries, fn {tk, _v, ts} ->
        case :ets.lookup(@table, tk) do
          [{_, _, mine}] -> ts > mine
          [] -> true
        end
      end)

    state = Enum.reduce(entries, state, fn {_, _, ts}, st -> observe(st, ts) end)
    apply_entries(fresh, state)
  end

  defp apply_entries([], state), do: state

  defp apply_entries(entries, state) do
    :ets.insert(@table, entries)
    :ok = :file.write(state.log, Enum.map(entries, &frame/1))

    for {{table, key}, value, _ts} <- entries do
      SSI.Events.publish({:store, table}, {:ssi_store, table, key, if(value == @tomb, do: :deleted, else: value)})
    end

    %{state | logged: state.logged + length(entries)}
  end

  defp frame(entry) do
    bin = :erlang.term_to_binary(entry)
    <<byte_size(bin)::32, bin::binary>>
  end

  # Replays the log and cuts it back to its last whole record. Power loss
  # mid-append leaves a torn record, or (ext4 delayed allocation) a tail of
  # zeros the file was extended by but never written; appending after such
  # a tail would hide every later record from the next replay.
  defp replay(path) do
    case File.read(path) do
      {:ok, data} ->
        {n, good} = replay_frames(data, 0, 0)

        if good < byte_size(data) do
          Logger.warning("store: dropped #{byte_size(data) - good} bytes of torn log after #{n} entries")
          truncate(path, good)
        end

        n

      _ ->
        0
    end
  end

  defp replay_frames(<<size::32, bin::binary-size(size), rest::binary>> = data, n, at) when size > 0 do
    case decode(bin) do
      {tk, _v, ts} = entry ->
        case :ets.lookup(@table, tk) do
          [{_, _, mine}] when mine >= ts -> :ok
          _ -> :ets.insert(@table, entry)
        end

        replay_frames(rest, n + 1, at + byte_size(data) - byte_size(rest))

      :torn ->
        {n, at}
    end
  end

  defp replay_frames(_, n, at), do: {n, at}

  defp decode(bin) do
    case :erlang.binary_to_term(bin) do
      {{_table, _key}, _value, _ts} = entry -> entry
      _ -> :torn
    end
  rescue
    ArgumentError -> :torn
  end

  defp truncate(path, size) do
    {:ok, f} = :file.open(String.to_charlist(path), [:read, :write, :raw, :binary])
    {:ok, _} = :file.position(f, size)
    :ok = :file.truncate(f)
    :file.close(f)
  end

  defp maybe_compact(state) do
    live = :ets.info(@table, :size)

    if state.logged > 2 * live + 1_000 do
      tmp = state.path <> ".tmp"
      File.write!(tmp, :ets.tab2list(@table) |> Enum.map(&frame/1))
      :file.close(state.log)
      File.rename!(tmp, state.path)
      {:ok, log} = :file.open(String.to_charlist(state.path), [:append, :raw, :binary])
      %{state | log: log, logged: live}
    else
      state
    end
  end

  # -- anti-entropy -----------------------------------------------------------

  defp bucket(tk), do: :erlang.phash2(tk, @buckets)

  @doc false
  def digest do
    :ets.foldl(
      fn {tk, _v, ts}, acc ->
        b = bucket(tk)
        Map.update(acc, b, :erlang.phash2({tk, ts}), &Bitwise.bxor(&1, :erlang.phash2({tk, ts})))
      end,
      %{},
      @table
    )
  end

  @doc false
  def digest_entries, do: :ets.tab2list(@table)

  defp differing_buckets(theirs) do
    mine = digest()
    for b <- 0..(@buckets - 1), Map.get(mine, b) != Map.get(theirs, b), do: b
  end

  defp bucket_entries(buckets) do
    set = MapSet.new(buckets)
    :ets.foldl(fn {tk, _, _} = e, acc -> if MapSet.member?(set, bucket(tk)), do: [e | acc], else: acc end, [], @table)
  end
end
