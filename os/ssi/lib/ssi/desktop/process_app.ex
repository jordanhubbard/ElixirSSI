defmodule SSI.Desktop.ProcessApp do
  @moduledoc "The cluster's busiest processes, refreshed every two seconds."
  @behaviour SSI.Desktop.App
  alias SSI.Remote
  alias SSI.Desktop.App

  @refresh 2_000

  @impl true
  def short, do: "processes"
  @impl true
  def title, do: "Processes"
  @impl true
  def size, do: {566, 300}

  @impl true
  def init(_ctx), do: %{rows: [], prev: %{}, last: 0, busy: false, total: 0}

  @impl true
  def tick(%{busy: false} = state, ctx) do
    now = System.monotonic_time(:millisecond)

    if now - state.last >= @refresh do
      %{desktop: desktop, id: id} = ctx
      Task.start(fn -> send(desktop, {:app, id, {:procs, SSI.Proc.ps()}}) end)
      %{state | busy: true, last: now}
    else
      state
    end
  end

  def tick(state, _ctx), do: state

  @impl true
  def message({:procs, list}, state, _ctx) do
    rows =
      list
      |> Enum.map(&Map.put(&1, :delta, &1.reductions - Map.get(state.prev, &1.pid, &1.reductions)))
      |> Enum.sort_by(& &1.delta, :desc)
      |> Enum.take(22)

    %{state | rows: rows, prev: Map.new(list, &{&1.pid, &1.reductions}), busy: false, total: length(list)}
  end

  def message(_, state, _), do: state

  @impl true
  def render(state, ctx, {x, y, _w, _h}) do
    fb = ctx.fb

    header = [
      Remote.text(fb, x + 8, y + 6, "#{state.total} processes across #{SSI.Cluster.size()} machines - busiest by reductions/2s", 0x8A90A2),
      Remote.text(fb, x + 8, y + 20, "HOST:PID                  NAME                          REDS     MEM", 0x9CC3FF)
    ]

    rows =
      state.rows
      |> Enum.with_index()
      |> Enum.map(fn {p, i} ->
        ry = y + 34 + i * 11

        [
          Remote.text(fb, x + 8, ry, App.truncate(p.id, 25), App.node_color(p.node)),
          Remote.text(fb, x + 8 + 26 * 8, ry, App.truncate(p.name, 29), 0xE8EAF0),
          Remote.text(fb, x + 8 + 56 * 8, ry, String.pad_leading(Integer.to_string(p.delta), 8), 0xE5C07B),
          Remote.text(fb, x + 8 + 65 * 8, ry, SSI.Shell.Format.bytes(p.memory), 0x8A90A2)
        ]
      end)

    [header, rows]
  end
end
