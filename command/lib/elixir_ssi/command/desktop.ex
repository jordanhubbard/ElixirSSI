defmodule ElixirSSI.Command.Desktop do
  @moduledoc "Authenticated RemoteOS bridge: OTP owns the scene, browsers render it."
  use GenServer
  alias ElixirSSI.Command.{Store, Remote}

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  def frame, do: GenServer.call(__MODULE__, :frame)
  def input(event), do: GenServer.cast(__MODULE__, {:input, event})

  def enable(target, endpoint) do
    with [host, port] <- String.split(endpoint, ":"),
         true <- host != "",
         {port, ""} when port in 1..65535 <- Integer.parse(port) do
      token = GenServer.call(__MODULE__, :token)

      Remote.evaluate(target, """
      :ok = SSI.Desktop.enable(#{inspect(endpoint)}, token: #{inspect(token)})
      ready = Enum.find_value(1..100, fn _ ->
        Process.sleep(200)
        case SSI.Desktop.status() do
          %{connected: true, frames: frames} = status when frames > 0 -> status
          _ -> nil
        end
      end)
      ready || raise("Desktop did not connect. Check the command node address and port 4010 transport.")
      """)
    else
      _ ->
        {:error,
         "Enter the command node address and desktop port, such as host.docker.internal:4010."}
    end
  end

  @impl true
  def init(_) do
    path = Path.join(Store.directory(), "desktop-token")

    unless File.exists?(path) do
      File.write!(path, Base.url_encode64(:crypto.strong_rand_bytes(32)), [:exclusive])
      File.chmod!(path, 0o600)
    end

    port = Application.get_env(:ssi_command, :desktop_port, 4010)
    bind = Application.get_env(:ssi_command, :desktop_bind, {127, 0, 0, 1})

    {:ok, listener} =
      :gen_tcp.listen(port, [:binary, active: false, packet: :raw, reuseaddr: true, ip: bind])

    {:ok, _} = Task.Supervisor.start_child(ElixirSSI.Command.Tasks, fn -> accept(listener) end)

    {:ok,
     %{
       listener: listener,
       token: File.read!(path),
       owner: nil,
       surfaces: %{},
       ops: [],
       events: [],
       frame: nil,
       width: 1280,
       height: 800
     }}
  end

  @impl true
  def handle_call(:token, _, state), do: {:reply, state.token, state}
  def handle_call(:frame, _, state), do: {:reply, state.frame, state}

  def handle_call({:request, owner, "hello", params, _}, _, state) do
    if params["protocol"] == 2 and is_binary(params["token"]) and
         Plug.Crypto.secure_compare(params["token"], state.token) do
      {:reply, {:ok, %{protocol: 2, features: [], limits: %{batch_ops: 1024}}},
       %{state | owner: owner, surfaces: %{}, ops: [], events: [], frame: nil}}
    else
      {:reply, {:error, "Desktop authentication failed"}, state}
    end
  end

  def handle_call({:request, owner, op, params, payload}, _, %{owner: owner} = state) do
    try do
      {result, next} = request(op, params, payload, state)
      {:reply, {:ok, result}, next}
    rescue
      _ -> {:reply, {:error, "Invalid or unsupported desktop operation"}, state}
    end
  end

  def handle_call({:request, _, _, _, _}, _, state),
    do: {:reply, {:error, "Authenticate first"}, state}

  @impl true
  def handle_cast({:closed, owner}, %{owner: owner} = state) do
    frame = if state.frame, do: Map.put(state.frame, :connected, false)
    Phoenix.PubSub.broadcast(ElixirSSI.Command.PubSub, "desktop", :desktop_frame)
    {:noreply, %{state | owner: nil, frame: frame, events: []}}
  end

  def handle_cast({:closed, _}, state), do: {:noreply, state}

  def handle_cast({:input, event}, state) do
    valid =
      is_map(event) and event["kind"] in [1, 3, 4, 5] and
        Enum.all?(Map.take(event, ["x", "y", "button", "code"]), fn {_, v} ->
          is_integer(v) and v in -4096..1_073_741_906
        end) and
        (is_nil(event["text"]) or (is_binary(event["text"]) and byte_size(event["text"]) <= 8))

    events =
      if valid and length(state.events) < 128,
        do: state.events ++ [Map.take(event, ~w(kind x y button code text))],
        else: state.events

    {:noreply, %{state | events: events}}
  end

  defp request("display.open", %{"w" => w, "h" => h}, _, s)
       when w in 320..1920 and h in 200..1080 do
    {%{fb_handle: 1, w: w, h: h}, %{s | width: w, height: h, surfaces: %{1 => %{w: w, h: h}}}}
  end

  defp request("surface.create", %{"w" => w, "h" => h}, _, s) when w in 1..256 and h in 1..256 do
    true = map_size(s.surfaces) < 128

    true =
      w * h + Enum.sum(for {id, surface} <- s.surfaces, id != 1, do: surface.w * surface.h) <=
        524_288

    handle = map_size(s.surfaces) + 1
    {%{handle: handle}, %{s | surfaces: Map.put(s.surfaces, handle, %{w: w, h: h})}}
  end

  defp request("surface.upload", %{"handle" => handle}, payload, s) do
    %{w: w, h: h} = surface = Map.fetch!(s.surfaces, handle)
    true = handle != 1 and byte_size(payload) == w * h * 4

    {%{},
     %{
       s
       | surfaces: Map.put(s.surfaces, handle, Map.put(surface, :pixels, Base.encode64(payload)))
     }}
  end

  defp request("render.batch", %{"ops" => ops}, _, s) do
    true = is_list(ops) and length(ops) <= 1024 and length(ops) + length(s.ops) <= 8192

    true =
      Enum.all?(ops, &(&1["op"] in ~w(surface.fill_rect surface.line text.draw surface.blit)))

    {%{}, %{s | ops: s.ops ++ ops}}
  end

  defp request("frame.commit", _, _, s) do
    frame = %{connected: true, width: s.width, height: s.height, surfaces: s.surfaces, ops: s.ops}
    Phoenix.PubSub.broadcast(ElixirSSI.Command.PubSub, "desktop", :desktop_frame)
    {%{events: s.events}, %{s | frame: frame, ops: [], events: []}}
  end

  defp request("event.poll", _, _, s), do: {%{events: s.events}, %{s | events: []}}

  defp accept(listener) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        session = make_ref()

        try do
          serve(socket, session)
        rescue
          _ -> :ok
        after
          :gen_tcp.close(socket)
          GenServer.cast(__MODULE__, {:closed, session})
        end

        accept(listener)

      {:error, _} ->
        :ok
    end
  end

  defp serve(socket, session) do
    with {:ok, <<length::32>>} when length in 1..1_048_576 <- :gen_tcp.recv(socket, 4, 10_000),
         {:ok, json} <- :gen_tcp.recv(socket, length, 3000),
         {:ok, %{"v" => 2, "op" => op, "id" => id, "params" => params}} <- Jason.decode(json),
         true <- is_map(params) and is_integer(id) and id >= 0 and is_binary(op),
         size when is_integer(size) and size in 0..262_144 <- Map.get(params, "payload_len", 0),
         {:ok, payload} <- if(size == 0, do: {:ok, <<>>}, else: :gen_tcp.recv(socket, size, 3000)) do
      result = GenServer.call(__MODULE__, {:request, session, op, params, payload})

      reply =
        case result do
          {:ok, value} -> %{id: id, ok: true, result: value}
          {:error, why} -> %{id: id, ok: false, error: why}
        end

      bytes = Jason.encode!(reply)
      if id != 0, do: :gen_tcp.send(socket, [<<byte_size(bytes)::32>>, bytes])
      if match?({:ok, _}, result), do: serve(socket, session)
    else
      _ -> :ok
    end
  end
end
