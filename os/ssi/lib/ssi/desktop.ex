defmodule SSI.Desktop do
  @moduledoc """
  The cluster desktop: a compositor that draws on a RemoteOS-SDL service.

  The desktop is a cluster *service* (`SSI.Service`), not a program on a
  particular Pi. It connects out to the RemoteOS-SDL service on the user's
  workstation, renders a menu bar, a dock and overlapping windows, and routes
  input to applications. Because it is a service, it fails over: unplug the
  member drawing the desktop and another member starts it, restores the open
  windows from its checkpoint and reconnects — the menu bar's
  "drawn by" field changes, and nothing else does.

  Applications implement `SSI.Desktop.App`. Their state lives in this process;
  their heavy work runs anywhere in the cluster and reports back by message.
  """
  use GenServer
  require Logger
  alias SSI.Remote

  @tick 40
  @redraw_ms 1_000
  @menu_h 22
  @dock_h 44
  @title_h 20
  @apps [SSI.Desktop.ClusterApp, SSI.Desktop.ProcessApp, SSI.Desktop.MandelbrotApp, SSI.Desktop.ShellApp]

  @bg 0x1B1F2A
  @menu 0x0E1016
  @chrome 0x343B4D
  @focus 0x4C6FBF
  @frame 0x5A6378
  @fg 0xE8EAF0
  @dim 0x8A90A2

  # -- control ----------------------------------------------------------------

  @doc "Register the desktop service targeting a RemoteOS-SDL `host:port`."
  def enable(endpoint, opts \\ []) when is_binary(endpoint) do
    SSI.Service.register(:desktop, __MODULE__, %{endpoint: endpoint, token: opts[:token], size: opts[:size] || SSI.Config.get("desktop.size")})
  end

  def disable, do: SSI.Service.unregister(:desktop)

  @doc "Registers the desktop at boot when `desktop` is configured."
  def autostart do
    case SSI.Config.get("desktop") do
      nil -> :ok
      endpoint -> if SSI.Service.spec(:desktop) == nil, do: Task.start(fn -> enable(endpoint) end)
    end
  end

  @doc "Status of the running desktop, wherever it is."
  def status, do: SSI.Service.call(:desktop, :status, 15_000)

  @doc "Ask the RemoteOS host to save a PNG of the desktop at `host_path`."
  def capture(host_path), do: SSI.Service.call(:desktop, {:capture, host_path}, 15_000)

  @doc """
  Queue input events on the RemoteOS host as if a user produced them
  (automation and demos). Each event is a map with `kind` (1 key down,
  3 mouse move, 4 mouse down, 5 mouse up) and `x`, `y`, `button`, `code`,
  `text` as applicable. Helpers: `type/1`, `click/3`.
  """
  def inject(events), do: SSI.Service.call(:desktop, {:inject, events}, 15_000)

  @doc "Type text (and optionally Return) into the focused window."
  def type(text, return? \\ true) do
    keys = for <<c::utf8 <- text>>, do: %{kind: 1, code: c, text: <<c::utf8>>}
    inject(keys ++ if(return?, do: [%{kind: 1, code: 13}], else: []))
  end

  @doc "Click at desktop coordinates."
  def click(x, y, button \\ 1), do: inject([%{kind: 4, x: x, y: y, button: button}, %{kind: 5, x: x, y: y, button: button}])

  @doc "State of an open application (debugging and tests)."
  def app_state(app), do: SSI.Service.call(:desktop, {:app_state, app}, 15_000)

  @doc "Open an application window (by module or short name)."
  def open(app), do: SSI.Service.call(:desktop, {:open, app}, 15_000)

  @doc "Open or restart an installed user desktop application."
  def launch(app), do: SSI.Service.call(:desktop, {:launch, app}, 15_000)

  def start_link(args), do: GenServer.start_link(__MODULE__, args)

  # -- server -----------------------------------------------------------------

  @impl true
  def init(args) do
    Process.flag(:trap_exit, true)
    {w, h} = parse_size(args[:size] || "1280x800")
    saved = SSI.Service.restore(:desktop) || %{}

    state = %{
      endpoint: args.endpoint,
      token: args[:token],
      conn: nil,
      fb: nil,
      w: w,
      h: h,
      windows: [],
      next_id: 1,
      drag: nil,
      mouse: {0, 0},
      dirty: true,
      last_draw: 0,
      tiles: [],
      upload_queue: %{},
      frames: 0,
      connected_at: nil,
      error: nil,
      checkpoint_timer: nil,
      restored: saved != %{}
    }

    state =
      case saved[:windows] do
        [_ | _] = wins -> Enum.reduce(wins, state, fn {app, x, y, saved}, st ->
          if app in @apps or user_app(app), do: open_window(st, app, {x, y}, saved), else: st
        end)
        _ -> default_windows(state)
      end

    send(self(), :connect)
    Process.send_after(self(), :checkpoint, 5_000)
    {:ok, state}
  end

  defp default_windows(state) do
    state
    |> open_window(SSI.Desktop.ClusterApp, {16, @menu_h + 12})
    |> open_window(SSI.Desktop.MandelbrotApp, {640, @menu_h + 12})
    |> open_window(SSI.Desktop.ShellApp, {16, @menu_h + 420})
  end

  defp parse_size(text) do
    [w, h] = text |> to_string() |> String.split("x") |> Enum.map(&String.to_integer/1)
    {w, h}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply,
     %{
       node: node(),
       endpoint: state.endpoint,
       connected: state.conn != nil,
       frames: state.frames,
       windows: Enum.map(state.windows, & &1.app),
       error: state.error,
       restored: state.restored
     }, state}
  end

  def handle_call({:open, app}, _from, state) do
    mod = Enum.find(@apps, &(&1 == app or &1.short() == to_string(app))) || user_app(app)
    if mod, do: {:reply, :ok, open_window(state, mod, nil)}, else: {:reply, {:error, :unknown_app}, state}
  end


  def handle_call({:launch, app}, _from, state) do
    case user_app(app) do
      nil -> {:reply, {:error, :unknown_app}, state}
      mod ->
        state = case Enum.find(state.windows, &(&1.app == mod)) do
          nil -> state
          win -> close_window(state, win.id)
        end
        {:reply, :ok, open_window(state, mod, nil)}
    end
  end

  def handle_call({:inject, events}, _from, %{conn: %Remote{} = conn} = state) do
    conn =
      Enum.reduce(events, conn, fn ev, c ->
        {_, _, c} = Remote.call(c, "debug.event.inject", ev)
        c
      end)

    {:reply, :ok, %{state | conn: conn}}
  end

  def handle_call({:inject, _}, _from, state), do: {:reply, {:error, :not_connected}, state}

  def handle_call({:app_state, app}, _from, state) do
    {:reply, Enum.find_value(state.windows, &(&1.app == app && &1.state)), state}
  end

  # `path` is on the RemoteOS host, which writes the image (BMP).
  def handle_call({:capture, path}, _from, state) do
    reply =
      with %Remote{} = conn <- state.conn,
           {:ok, result, _} <- Remote.call(conn, "debug.capture", %{path: path}) do
        {:ok, result}
      else
        other -> {:error, other}
      end

    {:reply, reply, state}
  end

  @impl true
  def handle_info(:connect, state) do
    case connect(state) do
      {:ok, state} ->
        Logger.info("desktop: drawing on #{state.endpoint} (#{state.w}x#{state.h}) from #{SSI.Boot.hostname()}")
        send(self(), :tick)
        {:noreply, state}

      {:error, reason} ->
        if state.error != inspect(reason),
          do: Logger.warning("desktop: cannot reach #{state.endpoint}: #{inspect(reason)}; retrying")

        Process.send_after(self(), :connect, 2_000)
        {:noreply, %{state | error: inspect(reason)}}
    end
  end

  def handle_info(:tick, %{conn: nil} = state), do: {:noreply, state}

  def handle_info(:tick, state) do
    Process.send_after(self(), :tick, @tick)
    state = Enum.reduce(state.windows, state, &tick_app/2)

    case frame(state) do
      {:ok, state} -> {:noreply, state}
      {:error, reason, state} -> {:noreply, disconnect(state, reason)}
    end
  end

  def handle_info({:app, id, msg}, state) do
    {:noreply, update_window(state, id, fn win -> %{win | state: win.app.message(msg, win.state, ctx(state, win))} end) |> dirty() |> checkpoint_soon()}
  end

  # Periodic checkpoint, plus one shortly after any input or app change, so a
  # failover restores what the user last saw rather than a stale layout.
  def handle_info(:checkpoint, state) do
    Process.send_after(self(), :checkpoint, 5_000)
    {:noreply, write_checkpoint(state)}
  end

  def handle_info(:checkpoint_soon, state), do: {:noreply, write_checkpoint(%{state | checkpoint_timer: nil})}

  def handle_info({:EXIT, _, :normal}, state), do: {:noreply, state}
  def handle_info({:EXIT, _, _}, state), do: {:noreply, state}
  def handle_info(_, state), do: {:noreply, state}

  defp write_checkpoint(state) do
    SSI.Store.put(:service_state, :desktop, %{windows: saved_windows(state)})
    state
  end

  defp checkpoint_soon(%{checkpoint_timer: nil} = state),
    do: %{state | checkpoint_timer: Process.send_after(self(), :checkpoint_soon, 500)}

  defp checkpoint_soon(state), do: state

  @impl true
  def terminate(_reason, state) do
    SSI.Service.checkpoint(:desktop, %{windows: saved_windows(state)})
    if state.conn, do: Remote.close(state.conn)
    :ok
  end

  defp saved_windows(state) do
    for w <- state.windows do
      saved = if function_exported?(w.app, :checkpoint, 1), do: w.app.checkpoint(w.state)
      {w.app, w.x, w.y, saved}
    end
  end

  # -- connection -------------------------------------------------------------

  defp connect(state) do
    with {:ok, conn} <- Remote.connect(state.endpoint, "elixirssi-desktop", state.token),
         {:ok, display, conn} <- Remote.call(conn, "display.open", %{w: state.w, h: state.h, title: "ElixirSSI cluster desktop"}),
         {:ok, windows, conn} <- window_surfaces(state.windows, conn) do
      w = display["w"] || state.w
      h = display["h"] || state.h
      {:ok, %{state | conn: conn, fb: display["fb_handle"], w: w, h: h, windows: windows, upload_queue: %{}, dirty: true, connected_at: System.monotonic_time(:millisecond), error: nil}}
    end
  end

  defp window_surfaces(windows, conn) do
    Enum.reduce_while(windows, {:ok, [], conn}, fn win, {:ok, acc, connection} ->
      case app_surfaces(connection, win.app) do
        {:ok, tiles, connection} ->
          win = Map.put(win, :tiles, tiles)
          win = if function_exported?(win.app, :reset_surfaces, 1), do: %{win | state: win.app.reset_surfaces(win.state)}, else: win
          {:cont, {:ok, [win | acc], connection}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, windows, connection} -> {:ok, Enum.reverse(windows), connection}
      error -> error
    end
  end

  defp app_surfaces(nil, _), do: {:ok, [], nil}
  defp app_surfaces(conn, app) do
    if function_exported?(app, :tile_count, 0) and function_exported?(app, :tile_size, 0) do
      count = app.tile_count()
      size = app.tile_size()
      if is_integer(count) and count in 1..256 and is_integer(size) and size in 1..256,
        do: create_tiles(conn, count, size), else: {:error, :invalid_surface_request}
    else
      {:ok, [], conn}
    end
  end

  defp create_tiles(conn, n, size) do
    Enum.reduce_while(1..n, {:ok, [], conn}, fn _, {:ok, acc, c} ->
      case Remote.call(c, "surface.create", %{w: size, h: size}) do
        {:ok, %{"handle" => h}, c} -> {:cont, {:ok, [h | acc], c}}
        {:error, e, c} -> {:halt, {:error, e, c}}
      end
    end)
    |> case do
      {:ok, hs, c} -> {:ok, Enum.reverse(hs), c}
      {:error, e, _} -> {:error, e}
    end
  end

  defp disconnect(state, reason) do
    Logger.warning("desktop: connection lost: #{inspect(reason)}")
    if state.conn, do: Remote.close(state.conn)
    Process.send_after(self(), :connect, 1_000)
    %{state | conn: nil, error: inspect(reason)}
  end

  # -- frame ------------------------------------------------------------------

  defp frame(state) do
    now = System.monotonic_time(:millisecond)

    if state.dirty or now - state.last_draw >= @redraw_ms do
      with {:ok, state} <- uploads(state),
           {:ok, conn} <- Remote.batch(state.conn, compose(state)),
           {:ok, %{"events" => events}, conn} <- Remote.call(conn, "frame.commit") do
        state = %{state | conn: conn, dirty: map_size(state.upload_queue) > 0, last_draw: now, frames: state.frames + 1}
        {:ok, events |> Enum.reduce(state, &input/2) |> then(&if(events != [], do: checkpoint_soon(&1), else: &1))}
      else
        {:error, reason, conn} -> {:error, reason, %{state | conn: conn}}
        {:error, reason} -> {:error, reason, state}
      end
    else
      case Remote.call(state.conn, "event.poll") do
        {:ok, %{"events" => events}, conn} ->
          state = Enum.reduce(events, %{state | conn: conn}, &input/2)
          {:ok, if(events != [], do: checkpoint_soon(state), else: state)}

        {:error, reason, conn} -> {:error, reason, %{state | conn: conn}}
      end
    end
  end

  # Retain pending pixels across frames, coalescing updates for the same surface.
  # A bounded batch keeps input and control calls responsive during large renders.
  defp uploads(state) do
    pending =
      for win <- state.windows, function_exported?(win.app, :uploads, 2),
          item <- win.app.uploads(win.state, ctx(state, win)),
          do: item

    queued = Map.merge(state.upload_queue, Map.new(pending))
    batch = Enum.take(queued, 8)

    result =
      Enum.reduce_while(batch, {:ok, state.conn}, fn {handle, pixels}, {:ok, c} ->
        case Remote.call(c, "surface.upload", %{handle: handle}, pixels) do
          {:ok, _, c} -> {:cont, {:ok, c}}
          {:error, e, c} -> {:halt, {:error, e, c}}
        end
      end)

    case result do
      {:ok, conn} ->
        windows =
          Enum.map(state.windows, fn win ->
            if function_exported?(win.app, :uploaded, 1), do: %{win | state: win.app.uploaded(win.state)}, else: win
          end)

        {:ok, %{state | conn: conn, windows: windows, upload_queue: Map.drop(queued, Enum.map(batch, &elem(&1, 0)))}}

      error ->
        error
    end
  end

  defp compose(state) do
    fb = state.fb

    [
      Remote.fill(fb, 0, 0, state.w, state.h, @bg),
      wallpaper(state),
      Enum.map(state.windows, &window_ops(state, &1)),
      menu_bar(state),
      dock(state)
    ]
    |> List.flatten()
  end

  defp wallpaper(state) do
    fb = state.fb
    s = SSI.Cluster.summary()
    y = state.h - @dock_h - 30

    [
      Remote.text(fb, 20, y, "ElixirSSI  -  one system image, #{s.nodes} machines, #{s.cores} cores", @dim),
      Remote.text(fb, 20, y + 12, "drag windows by their title bar; the dock opens apps; the desktop itself fails over", 0x5A6070)
    ]
  end

  defp menu_bar(state) do
    fb = state.fb
    s = SSI.Cluster.summary()
    {{_, _, _}, {hh, mm, ss}} = :calendar.local_time()
    clock = :io_lib.format("~2..0B:~2..0B:~2..0B", [hh, mm, ss]) |> to_string()

    right =
      "#{s.nodes} nodes  #{s.cores} cores  #{SSI.Shell.Format.bytes(s.memory)}  #{SSI.Proc.count()} procs   drawn by #{SSI.Boot.hostname()}   #{clock}"

    [
      Remote.fill(fb, 0, 0, state.w, @menu_h, @menu),
      Remote.text(fb, 10, 7, "ElixirSSI", 0x9CC3FF),
      Remote.text(fb, 96, 7, "cluster \"#{s.cluster}\"", @fg),
      Remote.text(fb, state.w - 8 * String.length(right) - 10, 7, right, @fg)
    ]
  end

  defp dock_buttons(state) do
    w = 120
    total = length(@apps) * (w + 10) - 10
    x0 = div(state.w - total, 2)
    y = state.h - @dock_h + 8

    @apps |> Enum.with_index() |> Enum.map(fn {app, i} -> {app, {x0 + i * (w + 10), y, w, @dock_h - 16}} end)
  end

  defp dock(state) do
    fb = state.fb

    [
      Remote.fill(fb, 0, state.h - @dock_h, state.w, @dock_h, @menu),
      for {app, {x, y, w, h}} <- dock_buttons(state) do
        open? = Enum.any?(state.windows, &(&1.app == app))
        label = String.capitalize(app.short())

        [
          Remote.fill(fb, x, y, w, h, if(open?, do: 0x2E3B5E, else: 0x23283A)),
          Remote.rect(fb, x, y, w, h, if(open?, do: @focus, else: @frame)),
          Remote.text(fb, x + div(w - 8 * String.length(label), 2), y + div(h - 8, 2), label, @fg)
        ]
      end
    ]
  end

  defp window_ops(state, win) do
    fb = state.fb
    focused = win.id == (List.last(state.windows) || %{id: nil}).id
    {x, y, w, h} = {win.x, win.y, win.w, win.h}
    body = {x + 1, y + @title_h, w - 2, h - @title_h - 1}

    [
      Remote.fill(fb, x + 4, y + 4, w, h, 0x0B0D12),
      Remote.fill(fb, x, y, w, h, 0x222736),
      Remote.fill(fb, x, y, w, @title_h, if(focused, do: @focus, else: @chrome)),
      Remote.text(fb, x + 8, y + 6, win.app.title(), @fg),
      Remote.fill(fb, x + w - 18, y + 4, 12, 12, 0xC0504D),
      Remote.text(fb, x + w - 16, y + 6, "x", 0xFFFFFF),
      Remote.rect(fb, x, y, w, h, if(focused, do: @focus, else: @frame)),
      win.app.render(win.state, ctx(state, win), body)
    ]
  end

  defp user_app(app) when is_atom(app) do
    with {:module, ^app} <- Code.ensure_loaded(app),
         owner when is_atom(owner) <- Application.get_application(app),
         true <- is_binary(SSI.Deploy.installed()[Atom.to_string(owner)]),
         true <- Enum.all?([short: 0, title: 0, size: 0, init: 1, render: 3, message: 3], fn {name, arity} -> function_exported?(app, name, arity) end) do
      app
    else
      _ -> nil
    end
  end
  defp user_app(_), do: nil

  # -- windows ----------------------------------------------------------------

  defp open_window(state, app, pos, saved \\ nil) do
    case Enum.find(state.windows, &(&1.app == app)) do
      nil ->
        Code.ensure_loaded!(app)
        {w, h} = app.size()
        id = state.next_id
        {x, y} = pos || {80 + rem(id * 37, 300), @menu_h + 30 + rem(id * 29, 200)}
        win = %{id: id, app: app, x: x, y: y, w: w, h: h + @title_h, state: nil, tiles: []}
        {win, state} = case app_surfaces(state.conn, app) do
          {:ok, tiles, conn} -> {%{win | tiles: tiles}, %{state | conn: conn}}
          {:error, why} -> {win, disconnect(state, why)}
        end
        ctx = ctx(state, win)

        app_state =
          if saved != nil and function_exported?(app, :restore, 2), do: app.restore(saved, ctx), else: app.init(ctx)

        win = %{win | state: app_state}
        %{state | windows: state.windows ++ [win], next_id: id + 1, dirty: true}

      win ->
        raise_window(state, win.id)
    end
  end

  defp close_window(state, id) do
    win = Enum.find(state.windows, &(&1.id == id))
    if win && function_exported?(win.app, :close, 1), do: win.app.close(win.state)
    state = if win && state.conn do
      conn = Enum.reduce(Map.get(win, :tiles, []), state.conn, fn handle, conn ->
        case Remote.call(conn, "surface.destroy", %{handle: handle}) do
          {:ok, _, conn} -> conn
          {:error, _, conn} -> conn
        end
      end)
      %{state | conn: conn}
    else
      state
    end
    %{state | windows: Enum.reject(state.windows, &(&1.id == id)), upload_queue: Map.drop(state.upload_queue, if(win, do: Map.get(win, :tiles, []), else: [])), dirty: true}
  end

  defp raise_window(state, id) do
    {win, rest} = Enum.split_with(state.windows, &(&1.id == id))
    %{state | windows: rest ++ win, dirty: true}
  end

  defp update_window(state, id, fun) do
    %{state | windows: Enum.map(state.windows, fn w -> if w.id == id, do: fun.(w), else: w end)}
  end

  defp tick_app(win, state) do
    if function_exported?(win.app, :tick, 2) do
      case win.app.tick(win.state, ctx(state, win)) do
        {:dirty, s} -> update_window(state, win.id, &%{&1 | state: s}) |> dirty()
        s -> update_window(state, win.id, &%{&1 | state: s})
      end
    else
      state
    end
  end

  defp dirty(state), do: %{state | dirty: true}

  @doc false
  def ctx(state, win) do
    %{desktop: self(), id: win.id, tiles: Map.get(win, :tiles, []), fb: state.fb}
  end

  # -- input ------------------------------------------------------------------

  defp input(%{"kind" => 4, "x" => x, "y" => y} = ev, state) do
    state = %{state | mouse: {x, y}}

    case Enum.find(dock_buttons(state), fn {_, r} -> inside?(r, x, y) end) do
      {app, _} ->
        case Enum.find(state.windows, &(&1.app == app)) do
          nil -> open_window(state, app, nil)
          win -> raise_window(state, win.id)
        end

      nil ->
        case window_at(state, x, y) do
          nil ->
            state

          win ->
            state = raise_window(state, win.id)

            cond do
              inside?({win.x + win.w - 18, win.y + 4, 12, 12}, x, y) -> close_window(state, win.id)
              y < win.y + @title_h -> %{state | drag: {win.id, x - win.x, y - win.y}}
              true -> deliver(state, win, Map.merge(ev, %{"x" => x - win.x - 1, "y" => y - win.y - @title_h}))
            end
        end
    end
  end

  defp input(%{"kind" => 3, "x" => x, "y" => y}, %{drag: {id, dx, dy}} = state) do
    update_window(%{state | mouse: {x, y}}, id, &%{&1 | x: max(x - dx, -&1.w + 40), y: max(y - dy, @menu_h)}) |> dirty()
  end

  defp input(%{"kind" => 3, "x" => x, "y" => y}, state), do: %{state | mouse: {x, y}}
  defp input(%{"kind" => 5}, state), do: %{state | drag: nil}

  defp input(%{"kind" => 1} = ev, state) do
    case List.last(state.windows) do
      nil -> state
      win -> deliver(state, win, ev)
    end
  end

  defp input(_, state), do: state

  defp deliver(state, win, ev) do
    if function_exported?(win.app, :event, 3) do
      update_window(state, win.id, &%{&1 | state: win.app.event(ev, &1.state, ctx(state, win))}) |> dirty()
    else
      state
    end
  end

  defp window_at(state, x, y) do
    state.windows |> Enum.reverse() |> Enum.find(&inside?({&1.x, &1.y, &1.w, &1.h}, x, y))
  end

  defp inside?({rx, ry, rw, rh}, x, y), do: x >= rx and x < rx + rw and y >= ry and y < ry + rh
end
