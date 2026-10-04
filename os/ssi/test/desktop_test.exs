defmodule SSI.DesktopTest do
  use ExUnit.Case, async: true
  alias SSI.Desktop.MandelbrotApp
  alias SSI.Demo.Mandelbrot

  test "every Mandelbrot tile lands at its own position" do
    ctx = %{desktop: self(), id: 7, tiles: Enum.to_list(101..196), fb: 1}
    state = MandelbrotApp.init(ctx)

    state =
      Enum.reduce(1..(MandelbrotApp.tile_count() + 1), state, fn _, st ->
        receive do
          {:app, 7, msg} -> MandelbrotApp.message(msg, st, ctx)
        after
          30_000 -> flunk("render did not finish")
        end
      end)

    assert map_size(state.tiles) == MandelbrotApp.tile_count()
    assert state.elapsed != nil

    # Tile 13 is row 1, column 1 of the 12-column grid.
    {_node, pixels} = state.tiles[13]
    assert pixels == Mandelbrot.tile(Mandelbrot.default_view(), {50, 50, 50, 50}, 600, 400, 200)

    # Uploads pair each tile with its own surface handle.
    uploads = Map.new(MandelbrotApp.uploads(state, ctx))
    assert uploads[101 + 13] == pixels
  end
end

defmodule SSI.DesktopRestoreTest do
  use ExUnit.Case, async: true
  alias SSI.Desktop.{MandelbrotApp, ShellApp}

  test "apps carry their state across a desktop failover" do
    # The desktop traps exits; the shell evaluator is linked to it.
    Process.flag(:trap_exit, true)
    ctx = %{desktop: self(), id: 1, tiles: [], fb: 1}
    zoomed = %{cx: -0.75, cy: 0.1, span: 0.05}
    m = MandelbrotApp.restore(MandelbrotApp.checkpoint(%{view: zoomed, overlay: false}), ctx)
    assert m.view == zoomed and m.overlay == false and m.gen == 1

    s = ShellApp.restore(%{lines: ["ssi> 1 + 1", "2"], history: ["1 + 1"]}, ctx)
    assert ["ssi> 1 + 1", "2" | _] = s.lines
    assert s.history == ["1 + 1"]
    ShellApp.close(s)
  end
end
