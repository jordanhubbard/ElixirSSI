defmodule SSI.Load do
  @moduledoc """
  Per-node load sampling, gossiped to every member once a second.

  The sample that matters for a BEAM machine is *scheduler utilization* —
  the fraction of wall time the schedulers spent executing Erlang processes —
  measured exactly from `:erlang.statistics(:scheduler_wall_time)` rather than
  estimated from OS load averages. Each node keeps every member's latest
  sample plus a short history, so placement decisions (`SSI.Sched`) and the
  desktop's monitors read local memory only.
  """
  use GenServer

  @table :ssi_load
  @interval 1_000
  @history 60

  def start_link(_), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @doc "Latest sample for `node`, or nil."
  def get(node \\ node()) do
    case :ets.lookup(@table, node) do
      [{^node, sample}] -> sample
      [] -> nil
    end
  end

  @doc "Latest samples of all members, sorted by node."
  def cluster do
    SSI.Cluster.members() |> Enum.map(&get/1) |> Enum.reject(&is_nil/1)
  end

  @doc """
  Placement cost of a node: utilization plus queued work per scheduler. Lower
  is better; an idle node scores 0.0.
  """
  def score(node) do
    case get(node) do
      nil -> 10.0
      s -> s.util + s.run_queue / max(s.schedulers, 1)
    end
  end

  @doc "Physical memory of this machine in bytes."
  def total_memory do
    meminfo()["MemTotal"] || :erlang.memory(:total)
  end

  @impl true
  def init(_) do
    :ets.new(@table, [:named_table, :public, read_concurrency: true])
    :erlang.system_flag(:scheduler_wall_time, true)
    SSI.Events.subscribe(:membership)
    send(self(), :sample)
    {:ok, %{wall: :erlang.statistics(:scheduler_wall_time), history: []}}
  end

  @impl true
  def handle_info(:sample, state) do
    wall = :erlang.statistics(:scheduler_wall_time)
    util = utilization(state.wall, wall)
    history = Enum.take([util | state.history], @history)
    mem = meminfo()

    sample = %{
      node: node(),
      at: System.os_time(:millisecond),
      util: util,
      history: history,
      schedulers: :erlang.system_info(:schedulers_online),
      run_queue: :erlang.statistics(:total_run_queue_lengths),
      processes: :erlang.system_info(:process_count),
      beam_memory: :erlang.memory(:total),
      mem_total: mem["MemTotal"] || :erlang.memory(:total),
      mem_available: mem["MemAvailable"] || 0,
      temperature: temperature(),
      reductions: :erlang.statistics(:reductions) |> elem(1)
    }

    :ets.insert(@table, {node(), sample})
    GenServer.abcast(Node.list(), __MODULE__, {:sample, sample})
    Process.send_after(self(), :sample, @interval)
    {:noreply, %{state | wall: wall, history: history}}
  end

  def handle_info({:ssi_membership, :down, node}, state) do
    :ets.delete(@table, node)
    {:noreply, state}
  end

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def handle_cast({:sample, %{node: node} = sample}, state) do
    if node in Node.list(), do: :ets.insert(@table, {node, sample})
    {:noreply, state}
  end

  @doc false
  def utilization(before, now) do
    schedulers = :erlang.system_info(:schedulers)
    pick = fn list -> list |> Enum.filter(fn {id, _, _} -> id <= schedulers end) |> Map.new(fn {id, a, t} -> {id, {a, t}} end) end
    b = pick.(before)

    {active, total} =
      Enum.reduce(pick.(now), {0, 0}, fn {id, {a1, t1}}, {sa, st} ->
        {a0, t0} = Map.get(b, id, {0, 0})
        {sa + (a1 - a0), st + (t1 - t0)}
      end)

    if total > 0, do: Float.round(active / total, 3), else: 0.0
  end

  defp meminfo do
    case File.read("/proc/meminfo") do
      {:ok, text} ->
        for line <- String.split(text, "\n"),
            [key, value | _] <- [String.split(line, [":", " "], trim: true)],
            {kb, ""} <- [Integer.parse(value)],
            into: %{},
            do: {key, kb * 1024}

      _ ->
        %{}
    end
  end

  defp temperature do
    case File.read("/sys/class/thermal/thermal_zone0/temp") do
      {:ok, t} -> String.trim(t) |> String.to_integer() |> Kernel./(1000)
      _ -> nil
    end
  rescue
    _ -> nil
  end
end
