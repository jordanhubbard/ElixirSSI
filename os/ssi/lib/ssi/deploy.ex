defmodule SSI.Deploy do
  @moduledoc "Durable deployment of runtime OTP applications by authenticated operators."
  use GenServer
  require Logger
  @limit 67_108_864

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  def installed, do: GenServer.call(__MODULE__, :installed)
  def install(name, files), do: GenServer.call(__MODULE__, {:install, name, files}, 25_000)
  def begin_upload(id, hash, size), do: GenServer.call(__MODULE__, {:begin, id, hash, size})
  def append_upload(id, chunk), do: GenServer.call(__MODULE__, {:append, id, chunk})
  def finish_upload(id), do: GenServer.call(__MODULE__, {:finish, id}, 25_000)
  def cancel_upload(id), do: GenServer.call(__MODULE__, {:cancel, id})

  @impl true
  def init(_) do
    root = Path.join(SSI.Boot.data_dir(), "applications")
    File.mkdir_p!(root)
    File.rm(Path.join(root, ".upload"))
    send(self(), :restore)
    {:ok, %{root: root, apps: read_manifest(root), upload: nil}}
  end

  @impl true
  def handle_info(:restore, state) do
    case activate_all(state.root, state.apps) do
      :ok -> :ok
      {:error, why} -> Logger.error("deploy: user applications could not be restored: #{inspect(why)}")
    end
    {:noreply, state}
  end

  @impl true
  def handle_call(:installed, _, state), do: {:reply, state.apps, state}
  def handle_call({:begin, id, hash, size}, _, state) do
    if is_binary(id) and Regex.match?(~r/\A[0-9a-f]{32}\z/, id) and digest?(hash) and is_integer(size) and size in 1..@limit do
      :ok = File.write(Path.join(state.root, ".upload"), <<>>)
      upload = %{id: id, hash: hash, size: size, received: 0, deadline: System.monotonic_time(:second) + 600}
      {:reply, :ok, %{state | upload: upload}}
    else
      {:reply, {:error, "Invalid deployment transfer"}, state}
    end
  end
  def handle_call({:append, id, chunk}, _, %{upload: %{id: id} = upload} = state) do
    with true <- System.monotonic_time(:second) <= upload.deadline,
         true <- is_binary(chunk) and byte_size(chunk) <= 262_144,
         {:ok, bytes} <- Base.decode64(chunk),
         true <- upload.received + byte_size(bytes) <= upload.size,
         :ok <- File.write(Path.join(state.root, ".upload"), bytes, [:append]) do
      {:reply, :ok, %{state | upload: %{upload | received: upload.received + byte_size(bytes)}}}
    else
      _ -> {:reply, {:error, "Invalid, oversized or expired deployment chunk"}, state}
    end
  end
  def handle_call({:finish, id}, _, %{upload: %{id: id} = upload} = state) do
    result = with true <- upload.received == upload.size and System.monotonic_time(:second) <= upload.deadline,
                  {:ok, bytes} <- File.read(Path.join(state.root, ".upload")),
                  true <- hash(bytes) == upload.hash,
                  {:ok, %{"applications" => applications}} <- JSON.decode(bytes),
                  do: apply_bundle(applications, state)
    File.rm(Path.join(state.root, ".upload"))
    case result do
      {:ok, reply, apps} -> {:reply, {:ok, reply}, %{state | apps: apps, upload: nil}}
      {:error, why} -> {:reply, {:error, why}, %{state | upload: nil}}
      _ -> {:reply, {:error, "Incomplete or corrupt deployment transfer"}, %{state | upload: nil}}
    end
  end
  def handle_call({:cancel, id}, _, %{upload: %{id: id}} = state) do
    File.rm(Path.join(state.root, ".upload"))
    {:reply, :ok, %{state | upload: nil}}
  end
  def handle_call({:cancel, _}, _, state), do: {:reply, :ok, state}
  def handle_call({:append, _, _}, _, state), do: {:reply, {:error, "Unknown deployment transfer"}, state}
  def handle_call({:finish, _}, _, state), do: {:reply, {:error, "Unknown deployment transfer"}, state}
  def handle_call({:install, name, files}, _, state) do
    files = if is_map(files) and Enum.all?(Map.keys(files), &is_binary/1),
      do: Map.new(files, fn {path, bytes} -> {"ebin/" <> path, bytes} end), else: :invalid
    case apply_bundle(%{name => files}, state) do
      {:ok, _, apps} -> {:reply, {:ok, %{application: name, identity: apps[name], node: node()}}, %{state | apps: apps}}
      {:error, why} -> {:reply, {:error, why}, state}
    end
  end

  defp apply_bundle(applications, state) do
    with true <- is_map(applications) and map_size(applications) in 1..128,
         {:ok, prepared} <- validate_all(applications, state) do
      next = Enum.reduce(prepared, state.apps, fn item, acc -> Map.put(acc, item.name, item.digest) end)
      try do
        for item <- prepared, {file, bytes} <- item.files do
          path = Path.join([state.root, item.name, item.digest, item.name, file])
          File.mkdir_p!(Path.dirname(path))
          unless File.read(path) == {:ok, bytes}, do: durable_write!(path, bytes)
        end
        deactivate_all(state.root, state.apps)
        case activate_all(state.root, next) do
          :ok ->
            file = Path.join(state.root, "installed.json")
            durable_write!(file <> ".tmp", JSON.encode!(next))
            File.rename!(file <> ".tmp", file)
            SSI.Sys.sync()
            {:ok, %{applications: Map.take(next, Map.keys(applications)), node: node()}, next}
          {:error, why} -> rollback(state, next, why)
        end
      rescue
        error -> rollback(state, next, Exception.message(error))
      end
    else
      {:error, why} -> {:error, why}
      _ -> {:error, "Invalid application set"}
    end
  end

  defp rollback(state, next, why) do
    deactivate_all(state.root, next)
    result = activate_all(state.root, state.apps)
    {:error, "Activation failed: #{inspect(why)}; previous application restore: #{inspect(result)}"}
  end

  defp validate_all(applications, state) do
    prepared = Enum.map(applications, fn {name, files} -> validate!(name, files, state) end)
    modules = Enum.flat_map(prepared, & &1.modules)
    true = length(modules) == length(Enum.uniq(modules))
    true = Enum.sum(for app <- prepared, {_, bytes} <- app.files, do: byte_size(bytes)) <= 48 * 1024 * 1024
    {:ok, prepared}
  rescue
    _ -> {:error, "Invalid application bundle, missing modules or conflict with system code"}
  end

  defp validate!(name, files, state) do
    true = name?(name) and is_map(files) and map_size(files) in 1..4096
    decoded = Enum.map(files, fn {path, bytes} ->
      true = safe_file?(path) and is_binary(bytes)
      {path, Base.decode64!(bytes)}
    end)
    {_, app_bytes} = List.keyfind(decoded, "ebin/#{name}.app", 0)
    {:ok, tokens, _} = :erl_scan.string(String.to_charlist(app_bytes))
    {:ok, {:application, app, props}} = :erl_parse.parse_term(tokens)
    true = is_atom(app) and Atom.to_string(app) == name and Keyword.keyword?(props)
    true = state.apps[name] != nil or not Enum.any?(Application.loaded_applications(), fn {id, _, _} -> id == app end)
    modules = Keyword.fetch!(props, :modules)
    true = is_list(modules) and Enum.all?(modules, &is_atom/1)
    true = Enum.sort(Enum.filter(Map.keys(files), &String.starts_with?(&1, "ebin/"))) == Enum.sort(["ebin/#{name}.app" | Enum.map(modules, &"ebin/#{&1}.beam")])
    for module <- modules do
      {_, beam} = List.keyfind(decoded, "ebin/#{module}.beam", 0)
      {:ok, {^module, _}} = :beam_lib.chunks(beam, [:exports])
      existing = :code.which(module)
      owned = state.apps[name] && String.starts_with?(to_string(existing), Path.join(state.root, name) <> "/")
      true = existing == :non_existing or owned == true
    end
    %{name: name, modules: modules, files: decoded, digest: hash(:erlang.term_to_binary(Enum.sort(decoded)))}
  end

  defp safe_file?(path) when is_binary(path) do
    parts = Path.split(path)
    Path.type(path) == :relative and not String.contains?(path, ["\\", "\0"]) and
      Enum.all?(parts, &(&1 not in [".", "..", ""])) and
      (match?(["ebin", _], parts) or match?(["priv", _ | _], parts))
  end
  defp safe_file?(_), do: false
  defp name?(name), do: is_binary(name) and Regex.match?(~r/\A[a-z][a-z0-9_]{0,47}\z/, name)
  defp digest?(hash), do: is_binary(hash) and Regex.match?(~r/\A[0-9a-f]{64}\z/, hash)
  defp hash(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp read_manifest(root) do
    path = Path.join(root, "installed.json")
    case File.read(path) do
      {:ok, text} ->
        case JSON.decode(text) do
          {:ok, apps} when is_map(apps) -> Map.filter(apps, fn {name, hash} -> name?(name) and digest?(hash) end)
          _ ->
            File.rename(path, path <> ".invalid-#{System.os_time(:second)}")
            Logger.error("deploy: invalid deployment manifest quarantined; booting without user applications")
            %{}
        end
      {:error, :enoent} -> %{}
      {:error, why} -> Logger.error("deploy: cannot read manifest: #{inspect(why)}"); %{}
    end
  end

  defp code_path(root, name, digest) do
    path = Path.join([root, name, digest])
    nested = Path.join([path, name, "ebin"])
    if File.dir?(nested), do: nested, else: path
  end

  defp activate_all(root, apps) do
    for {name, digest} <- apps do
      true = Code.prepend_path(code_path(root, name, digest))
    end
    for {name, _} <- apps do
      app = String.to_atom(name)
      case Application.load(app) do
        :ok -> :ok
        {:error, {:already_loaded, ^app}} -> :ok
        error -> throw(error)
      end
    end
    for {name, digest} <- apps, module <- Application.spec(String.to_atom(name), :modules) || [] do
      path = Path.join(code_path(root, name, digest), Atom.to_string(module)) |> String.to_charlist()
      case :code.load_abs(path) do
        {:module, ^module} -> :ok
        error -> throw(error)
      end
    end
    included = Enum.flat_map(apps, fn {name, _} -> Application.spec(String.to_atom(name), :included_applications) || [] end)
    for {name, _} <- apps, app = String.to_atom(name), app not in included do
      case Application.ensure_all_started(app) do
        {:ok, _} -> :ok
        error -> throw(error)
      end
    end
    :ok
  rescue
    error -> {:error, Exception.message(error)}
  catch
    _, error -> {:error, error}
  end

  defp deactivate_all(root, apps) do
    names = Map.keys(apps)
    visit = fn visit, name, {order, seen} ->
      if MapSet.member?(seen, name) do
        {order, seen}
      else
        deps = Application.spec(String.to_atom(name), :applications) || []
        result = Enum.reduce(deps, {order, MapSet.put(seen, name)}, fn dep, acc ->
          dep = Atom.to_string(dep)
          if Map.has_key?(apps, dep), do: visit.(visit, dep, acc), else: acc
        end)
        {order, seen} = result
        {[name | order], seen}
      end
    end
    {order, _} = Enum.reduce(names, {[], MapSet.new()}, fn name, acc -> visit.(visit, name, acc) end)
    for name <- order, do: Application.stop(String.to_atom(name))
    for name <- order do
      app = String.to_atom(name)
      modules = Application.spec(app, :modules) || []
      Application.unload(app)
      for module <- modules do
        :code.purge(module)
        :code.delete(module)
      end
      Code.delete_path(code_path(root, name, apps[name]))
    end
  end

  defp durable_write!(path, bytes) do
    {:ok, file} = :file.open(String.to_charlist(path), [:write, :binary, :raw])
    try do
      :ok = :file.write(file, bytes)
      :ok = :file.sync(file)
    after
      :file.close(file)
    end
  end
end
