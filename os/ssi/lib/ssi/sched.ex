defmodule SSI.Sched do
  @moduledoc """
  Cluster-wide placement of computation.

  The aggregate machine has as many cores as all members together. `spawn/1`
  and `run/1` place one computation on the member with the lowest load score
  (`SSI.Load.score/1`). `pmap/3` and `each/4` farm a collection out over every
  scheduler in the cluster:

    * each member gets as many in-flight items as it has schedulers;
    * membership is re-read on every dispatch, so a node that joins mid-run
      starts receiving work immediately;
    * an item whose node fails (or whose task crashes) is re-queued and run
      elsewhere, up to `:retries` times.

  Work runs under `SSI.TaskSup`, a `Task.Supervisor` present on every node.
  """

  @doc "The least loaded member."
  def best_node(exclude \\ []) do
    case SSI.Cluster.members() -- exclude do
      [] -> node()
      nodes -> Enum.min_by(nodes, &{SSI.Load.score(&1), :rand.uniform()})
    end
  end

  @doc "Spawn `fun` (or `{m, f, a}`) on the least loaded member; returns the pid."
  def spawn(fun) when is_function(fun, 0), do: Node.spawn(best_node(), fun)
  def spawn({m, f, a}), do: Node.spawn(best_node(), m, f, a)

  @doc "Run `fun` on the least loaded member and return its result."
  def run(fun, timeout \\ :infinity) do
    {:ok, result} = run_on(best_node(), fun, timeout)
    result
  end

  @doc "Run `fun` on `node` and return `{:ok, result}` or `{:error, reason}`."
  def run_on(node, fun, timeout \\ :infinity) do
    task = Task.Supervisor.async_nolink({SSI.TaskSup, node}, fun)

    case Task.yield(task, timeout) || Task.shutdown(task) do
      {:ok, result} -> {:ok, result}
      {:exit, reason} -> {:error, reason}
      nil -> {:error, :timeout}
    end
  end

  @doc "Parallel map over the whole cluster, preserving order."
  def pmap(enum, fun, opts \\ []) do
    items = Enum.to_list(enum)
    acc = :ets.new(:pmap, [:set, :private])
    each(items, fun, opts, fn index, _node, result -> :ets.insert(acc, {index, result}) end)
    result = for i <- 0..(length(items) - 1)//1, do: :ets.lookup_element(acc, i, 2)
    :ets.delete(acc)
    result
  end

  @doc """
  Run `fun` over `items` across the cluster, calling
  `on_result.(index, node, result)` in this process as each completes.
  Returns `%{nodes: %{node => items_done}, retried: n}`.

  Options: `:retries` (default 3), `:per_scheduler` in-flight items per
  scheduler (default 1), `:nodes` to restrict placement.
  """
  def each(items, fun, opts \\ [], on_result) do
    queue = items |> Enum.with_index() |> Enum.map(fn {item, i} -> {i, item, 0} end)

    state = %{
      queue: :queue.from_list(queue),
      inflight: %{},
      fun: fun,
      on_result: on_result,
      retries: Keyword.get(opts, :retries, 3),
      per: Keyword.get(opts, :per_scheduler, 1),
      only: opts[:nodes],
      done: %{},
      retried: 0
    }

    loop(dispatch(state))
  end

  defp loop(%{inflight: inflight} = state) when map_size(inflight) == 0 do
    if :queue.is_empty(state.queue) do
      %{nodes: state.done, retried: state.retried}
    else
      # Nothing could be placed (all nodes saturated or none reachable): wait briefly.
      Process.sleep(50)
      loop(dispatch(state))
    end
  end

  defp loop(state) do
    receive do
      {ref, {node, result}} when is_map_key(state.inflight, ref) ->
        Process.demonitor(ref, [:flush])
        {{index, _item, _tries}, _node} = state.inflight[ref]
        state.on_result.(index, node, result)

        state = %{state | inflight: Map.delete(state.inflight, ref), done: Map.update(state.done, node, 1, &(&1 + 1))}
        loop(dispatch(state))

      {:DOWN, ref, :process, _, reason} when is_map_key(state.inflight, ref) ->
        {{index, item, tries}, node} = state.inflight[ref]

        if tries >= state.retries do
          exit({:item_failed, index, node, reason})
        end

        state = %{
          state
          | inflight: Map.delete(state.inflight, ref),
            queue: :queue.in_r({index, item, tries + 1}, state.queue),
            retried: state.retried + 1
        }

        loop(dispatch(state))
    end
  end

  defp capacity(state) do
    nodes = state.only || SSI.Cluster.members()
    for n <- nodes, do: {n, max(SSI.Cluster.info(n)[:schedulers] || 1, 1) * state.per}
  end

  defp dispatch(state) do
    busy = Enum.frequencies(for {_ref, {_, n}} <- state.inflight, do: n)

    # Interleave free slots across nodes (least loaded first in each round),
    # so even a short job spreads over the whole cluster.
    free =
      for({n, cap} <- capacity(state), slots = cap - Map.get(busy, n, 0), slots > 0, do: {n, slots})
      |> Enum.sort_by(fn {n, _} -> SSI.Load.score(n) end)
      |> interleave()

    fill(state, free)
  end

  defp interleave([]), do: []

  defp interleave(nodes) do
    Enum.map(nodes, &elem(&1, 0)) ++
      interleave(for {n, slots} <- nodes, slots > 1, do: {n, slots - 1})
  end

  defp fill(state, []), do: state

  defp fill(state, [node | rest]) do
    case :queue.out(state.queue) do
      {:empty, _} ->
        state

      {{:value, {_i, item, _t} = job}, queue} ->
        fun = state.fun

        state =
          try do
            task = Task.Supervisor.async_nolink({SSI.TaskSup, node}, fn -> {node(), fun.(item)} end)
            %{state | queue: queue, inflight: Map.put(state.inflight, task.ref, {job, node})}
          catch
            # The node vanished between membership read and spawn: retry elsewhere.
            :exit, _ -> state
          end

        fill(state, rest)
    end
  end
end
