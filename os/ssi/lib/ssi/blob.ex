defmodule SSI.Blob do
  @moduledoc """
  Cluster-wide content-addressed storage for file data.

  A blob is named by the SHA-256 of its content and stored on `replicas`
  members chosen by rendezvous (highest-random-weight) hashing over the
  current membership. Every node can compute the holders of any blob without
  asking anyone, adding a node moves only the blobs it now ranks highest for,
  and losing a node leaves every blob with `replicas - 1` copies until repair
  re-replicates it.

  Repair runs on every membership change: each node offers the blobs it holds
  to their current holders and drops local copies it no longer needs once
  enough holders confirm a copy. Garbage collection removes blobs no file
  references (see `SSI.FS.Cluster`).
  """
  use GenServer
  require Logger

  @gc_grace_s 600

  def start_link(_), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  def replicas, do: min(SSI.Config.integer("replicas", 2), SSI.Cluster.size())

  @doc "Hex SHA-256 name of `data`."
  def hash(data), do: :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)

  @doc "Members that should hold `hash`, best first."
  def holders(hash, members \\ SSI.Cluster.members()) do
    members
    |> Enum.sort_by(&:crypto.hash(:sha256, [hash, Atom.to_string(&1)]), :desc)
    |> Enum.take(min(SSI.Config.integer("replicas", 2), length(members)))
  end

  @doc "Store `data` on its holders. Returns `{:ok, hash}` once at least one copy is durable."
  def put(data) do
    h = hash(data)
    targets = holders(h)

    results =
      Enum.map(targets, fn
        n when n == node() -> local_put(h, data)
        n -> rpc(n, :local_put, [h, data])
      end)

    if Enum.any?(results, &(&1 == :ok)), do: {:ok, h}, else: {:error, :no_holder}
  end

  @doc "Fetch a blob from wherever a copy exists."
  def get(h) do
    case local_get(h) do
      {:ok, data} ->
        {:ok, data}

      _ ->
        targets = holders(h)
        others = SSI.Cluster.peers() -- targets

        Enum.find_value((targets -- [node()]) ++ others, {:error, :not_found}, fn n ->
          case rpc(n, :local_get, [h]) do
            {:ok, data} ->
              if node() in targets, do: local_put(h, data)
              {:ok, data}

            _ ->
              nil
          end
        end)
    end
  end

  # -- local copies -----------------------------------------------------------

  defp dir, do: Path.join(SSI.Boot.data_dir(), "blobs")
  defp path(h), do: Path.join([dir(), binary_part(h, 0, 2), h])

  def local_put(h, data) do
    if hash(data) != h do
      {:error, :corrupt}
    else
      p = path(h)

      if File.exists?(p) do
        :ok
      else
        File.mkdir_p!(Path.dirname(p))
        tmp = p <> ".tmp" <> Integer.to_string(System.unique_integer([:positive]))
        File.write!(tmp, data)
        File.rename!(tmp, p)
        :ok
      end
    end
  end

  def local_get(h) do
    case File.read(path(h)) do
      {:ok, data} -> if hash(data) == h, do: {:ok, data}, else: {:error, :corrupt}
      error -> error
    end
  end

  def local_has?(h), do: File.exists?(path(h))

  @doc "Which of `hashes` this node lacks."
  def missing(hashes), do: Enum.reject(hashes, &local_has?/1)

  def local_list do
    Path.wildcard(Path.join(dir(), "??/*")) |> Enum.map(&Path.basename/1) |> Enum.reject(&String.contains?(&1, "."))
  end

  def local_stats do
    files = Path.wildcard(Path.join(dir(), "??/*"))
    %{blobs: length(files), bytes: files |> Enum.map(&File.stat!(&1).size) |> Enum.sum()}
  end

  @doc "Delete local blobs not in `referenced` and older than the grace period."
  def gc_local(referenced) do
    now = System.os_time(:second)

    for h <- local_list(), not MapSet.member?(referenced, h),
        {:ok, %{mtime: mtime}} <- [File.stat(path(h), time: :posix)],
        now - mtime > @gc_grace_s do
      File.rm(path(h))
      h
    end
  end

  defp rpc(n, fun, args) do
    :erpc.call(n, __MODULE__, fun, args, 15_000)
  catch
    _, reason -> {:error, reason}
  end

  # -- repair -----------------------------------------------------------------

  @doc "Re-replicate under-replicated local blobs now; returns blobs copied."
  def repair, do: GenServer.call(__MODULE__, :repair, 120_000)

  @impl true
  def init(_) do
    SSI.Events.subscribe(:membership)
    {:ok, %{timer: nil}}
  end

  @impl true
  def handle_call(:repair, _from, state), do: {:reply, do_repair(), state}

  @impl true
  def handle_info({:ssi_membership, _, _}, state) do
    # Debounce: a node joining produces a burst of events.
    if state.timer, do: Process.cancel_timer(state.timer)
    {:noreply, %{state | timer: Process.send_after(self(), :repair, 2_000)}}
  end

  def handle_info(:repair, state) do
    copied = do_repair()
    if copied > 0, do: Logger.info("blob: repaired #{copied} copies")
    {:noreply, %{state | timer: nil}}
  end

  def handle_info(_, state), do: {:noreply, state}

  defp do_repair do
    members = SSI.Cluster.members()
    local = local_list()

    by_holder =
      Enum.reduce(local, %{}, fn h, acc ->
        Enum.reduce(holders(h, members) -- [node()], acc, fn n, a -> Map.update(a, n, [h], &[h | &1]) end)
      end)

    copied =
      Enum.reduce(by_holder, 0, fn {n, hashes}, count ->
        case rpc(n, :missing, [hashes]) do
          list when is_list(list) ->
            Enum.each(list, fn h -> with {:ok, data} <- local_get(h), do: rpc(n, :local_put, [h, data]) end)
            count + length(list)

          _ ->
            count
        end
      end)

    # Drop copies this node is no longer a holder for, once all holders have one.
    for h <- local, node() not in holders(h, members) do
      if Enum.all?(holders(h, members), &(rpc(&1, :missing, [[h]]) == [])), do: File.rm(path(h))
    end

    copied
  end
end
