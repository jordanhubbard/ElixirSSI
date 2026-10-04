defmodule SSI.Desktop.MandelbrotApp do
  @moduledoc """
  The Mandelbrot set rendered by the whole cluster, one tile per task.

  Each tile is computed wherever `SSI.Sched` places it and outlined in the
  colour of the machine that computed it, so the picture doubles as a map of
  the scheduler's decisions. Add a Pi mid-render and its colour appears; pull
  one out and its in-flight tiles are recomputed elsewhere. Click to zoom in,
  right-click to zoom out, `r` resets, `o` toggles the outlines.
  """
  @behaviour SSI.Desktop.App
  alias SSI.Remote
  alias SSI.Desktop.App
  alias SSI.Demo.Mandelbrot

  @tile 50
  @cols 12
  @rows 8
  @w @tile * @cols
  @h @tile * @rows

  def tile_size, do: @tile
  def tile_count, do: @cols * @rows

  @impl true
  def short, do: "mandelbrot"
  @impl true
  def title, do: "Mandelbrot - computed by the cluster"
  @impl true
  def size, do: {@w + 2, @h + 44}

  @impl true
  def init(ctx), do: render_view(base(), ctx)

  defp base do
    %{view: Mandelbrot.default_view(), gen: 0, tiles: %{}, pending: [], overlay: true, started: 0, elapsed: nil, nodes: %{}, retried: 0}
  end

  @impl true
  def checkpoint(state), do: %{view: state.view, overlay: state.overlay}

  @impl true
  def restore(saved, ctx), do: base() |> Map.merge(saved) |> render_view(ctx)

  defp max_iter(view), do: round(200 + 60 * :math.log2(max(3.2 / view.span, 1.0)))

  defp render_view(state, ctx) do
    gen = state.gen + 1
    %{desktop: desktop, id: id} = ctx
    view = state.view
    max = max_iter(view)

    # Centre tiles first: they are the expensive ones near the set.
    order =
      for(i <- 0..(@cols * @rows - 1), do: i)
      |> Enum.sort_by(fn i -> abs(rem(i, @cols) - @cols / 2) + abs(div(i, @cols) - @rows / 2) end)

    Task.start(fn ->
      stats =
        SSI.Sched.each(
          order,
          # Items are reordered, so each result carries its own tile number.
          fn i -> {i, Mandelbrot.tile(view, {rem(i, @cols) * @tile, div(i, @cols) * @tile, @tile, @tile}, @w, @h, max)} end,
          [],
          fn _index, node, {i, pixels} -> send(desktop, {:app, id, {:tile, gen, i, node, pixels}}) end
        )

      send(desktop, {:app, id, {:done, gen, stats}})
    end)

    %{state | gen: gen, tiles: %{}, pending: [], started: System.monotonic_time(:millisecond), elapsed: nil, nodes: %{}}
  end

  @impl true
  def message({:tile, gen, i, node, pixels}, %{gen: gen} = state, _ctx) do
    %{state | tiles: Map.put(state.tiles, i, {node, pixels}), pending: [i | state.pending]}
  end

  def message({:done, gen, stats}, %{gen: gen} = state, _ctx) do
    %{state | elapsed: System.monotonic_time(:millisecond) - state.started, nodes: stats.nodes, retried: stats.retried}
  end

  def message(_, state, _), do: state

  @impl true
  def uploads(state, ctx) do
    for i <- Enum.uniq(state.pending), {_node, pixels} = state.tiles[i], do: {Enum.at(ctx.tiles, i), pixels}
  end

  @impl true
  def uploaded(state), do: %{state | pending: []}

  @impl true
  def reset_surfaces(state), do: %{state | pending: Map.keys(state.tiles)}

  @impl true
  def event(%{"kind" => 4, "x" => x, "y" => y, "button" => b}, state, ctx) when x < @w and y < @h do
    step = state.view.span / @w
    cx = state.view.cx - state.view.span / 2 + x * step
    cy = state.view.cy - step * @h / 2 + y * step
    factor = if b == 3, do: 2.5, else: 0.4
    render_view(%{state | view: %{cx: cx, cy: cy, span: min(state.view.span * factor, 4.0)}}, ctx)
  end

  def event(%{"kind" => 1, "text" => "r"}, state, ctx), do: render_view(%{state | view: Mandelbrot.default_view()}, ctx)
  def event(%{"kind" => 1, "text" => "o"}, state, _ctx), do: %{state | overlay: not state.overlay}
  def event(_, state, _), do: state

  @impl true
  def render(state, ctx, {x, y, _w, _h}) do
    fb = ctx.fb

    tiles =
      for i <- 0..(@cols * @rows - 1) do
        tx = x + rem(i, @cols) * @tile
        ty = y + div(i, @cols) * @tile

        case state.tiles[i] do
          nil ->
            Remote.fill(fb, tx, ty, @tile, @tile, 0x15171E)

          {node, _} ->
            blit = Remote.blit(Enum.at(ctx.tiles, i), fb, tx, ty, @tile, @tile)

            if state.overlay do
              c = App.node_color(node)
              [blit, Remote.line(fb, tx, ty, tx + @tile - 1, ty, c), Remote.line(fb, tx, ty, tx, ty + @tile - 1, c)]
            else
              blit
            end
        end
      end

    done = map_size(state.tiles)

    status =
      case state.elapsed do
        nil -> "rendering #{done}/#{@cols * @rows} tiles..."
        ms -> "#{@cols * @rows} tiles in #{ms} ms#{if state.retried > 0, do: ", #{state.retried} re-run after failures", else: ""}"
      end

    counts = Enum.frequencies(for {_, {n, _}} <- state.tiles, do: n)

    legend =
      counts
      |> Enum.sort()
      |> Enum.with_index()
      |> Enum.map(fn {{n, c}, i} ->
        lx = x + 8 + i * 150
        [Remote.fill(fb, lx, y + @h + 24, 10, 10, App.node_color(n)), Remote.text(fb, lx + 14, y + @h + 25, App.truncate("#{SSI.Cluster.hostname(n)} #{c}", 16), 0xE8EAF0)]
      end)

    [tiles, Remote.text(fb, x + 8, y + @h + 8, status <> "   click zoom, right-click out, r reset, o outlines", 0x8A90A2), legend]
  end
end
