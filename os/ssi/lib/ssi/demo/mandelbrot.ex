defmodule SSI.Demo.Mandelbrot do
  @moduledoc """
  The Mandelbrot set as a cluster workload: embarrassingly parallel, CPU-bound,
  and visibly uneven (tiles on the set's boundary cost far more), which makes
  the scheduler's load balancing observable.

  A view is `%{cx: real, cy: imag, span: width-in-complex-units}`.
  """

  @default %{cx: -0.6, cy: 0.0, span: 3.2}

  def default_view, do: @default

  @doc "Escape iterations for c = cr + ci·i, capped at `max`."
  def escape(cr, ci, max), do: iterate(0.0, 0.0, cr, ci, 0, max)

  defp iterate(_zr, _zi, _cr, _ci, n, max) when n >= max, do: max

  defp iterate(zr, zi, cr, ci, n, max) do
    zr2 = zr * zr
    zi2 = zi * zi

    if zr2 + zi2 > 4.0 do
      n
    else
      iterate(zr2 - zi2 + cr, 2.0 * zr * zi + ci, cr, ci, n + 1, max)
    end
  end

  defp coords(view, w, h) do
    step = view.span / w
    {view.cx - view.span / 2, view.cy - step * h / 2, step}
  end

  @doc "Iteration counts for row `y` of a `w`×`h` image."
  def row(view, y, w, h, max) do
    {x0, y0, step} = coords(view, w, h)
    ci = y0 + y * step
    for x <- 0..(w - 1), do: escape(x0 + x * step, ci, max)
  end

  @doc """
  Render tile `{tx, ty, tw, th}` of a `w`×`h` image as ARGB8888 pixels
  (little-endian B, G, R, X bytes) — the RemoteOS surface format.
  """
  def tile(view, {tx, ty, tw, th}, w, h, max) do
    {x0, y0, step} = coords(view, w, h)

    for y <- ty..(ty + th - 1), x <- tx..(tx + tw - 1), into: <<>> do
      n = escape(x0 + x * step, y0 + y * step, max)
      {r, g, b} = color(n, max)
      <<b, g, r, 255>>
    end
  end

  @doc "Smooth-ish palette; points in the set are black."
  def color(n, max) when n >= max, do: {0, 0, 0}

  def color(n, _max) do
    t = n / 64
    {wave(t, 0.0), wave(t, 2.1), wave(t, 4.2)}
  end

  defp wave(t, phase), do: round(127.5 + 127.5 * :math.sin(t * 6.2832 + phase))

  @doc "Character for an ASCII rendering."
  def glyph(n, max) when n >= max, do: "#"
  def glyph(n, _), do: String.at(" .:-=+*%@", min(div(n, 3), 8))
end
