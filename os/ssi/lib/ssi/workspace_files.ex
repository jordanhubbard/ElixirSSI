defmodule SSI.WorkspaceFiles do
  @moduledoc "Bounded authenticated workspace transfers, called over the operator SSH connection."
  use GenServer
  @max_file 16 * 1024 * 1024
  @chunk 96 * 1024
  @entries 2000
  @ttl 120_000

  def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  def request(params), do: GenServer.call(__MODULE__, params, 25_000)
  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call(params, _, state) do
    state = Map.reject(state, fn {_, upload} -> upload.expires < now() end)

    try do
      {result, state} = dispatch(params, state)

      reply =
        case result do
          :ok -> %{"ok" => true}
          {:ok, value} -> %{"ok" => value}
          {:error, reason} -> %{"error" => message(reason)}
        end

      {:reply, reply, state}
    rescue
      _ -> {:reply, %{"error" => "Invalid file request or unavailable filesystem."}, state}
    catch
      _, _ -> {:reply, %{"error" => "The selected node is unavailable."}, state}
    end
  end

  defp dispatch(
         %{
           "op" => "begin",
           "path" => path,
           "size" => size,
           "hash" => hash,
           "expected" => expected
         },
         state
       )
       when is_integer(size) and size >= 0 and size <= @max_file and is_binary(hash) do
    with :ok <- valid(path), true <- map_size(state) < 4, {:ok, ^expected} <- revision(path) do
      id = Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)

      upload = %{
        path: path,
        size: size,
        hash: hash,
        expected: expected,
        chunks: [],
        received: 0,
        expires: now() + @ttl
      }

      {{:ok, id}, Map.put(state, id, upload)}
    else
      {:ok, _} -> {{:error, "Destination changed. Refresh and confirm the overwrite."}, state}
      false -> {{:error, "Too many active transfers. Retry shortly."}, state}
      error -> {error, state}
    end
  end

  defp dispatch(%{"op" => "append", "id" => id, "offset" => offset, "data" => data}, state) do
    with %{received: ^offset} = upload <- state[id],
         true <- is_binary(data) and byte_size(data) <= div(@chunk * 4, 3) + 4,
         {:ok, bytes} <- Base.decode64(data),
         true <- byte_size(bytes) <= @chunk and offset + byte_size(bytes) <= upload.size do
      next = %{
        upload
        | chunks: [bytes | upload.chunks],
          received: offset + byte_size(bytes),
          expires: now() + @ttl
      }

      {{:ok, next.received}, Map.put(state, id, next)}
    else
      _ -> {{:error, "Transfer expired, exceeded its size or arrived out of order."}, state}
    end
  end

  defp dispatch(%{"op" => "finish", "id" => id}, state) do
    {upload, remaining} = Map.pop(state, id)

    result =
      with %{received: size, size: size} <- upload,
           bytes = upload.chunks |> Enum.reverse() |> IO.iodata_to_binary(),
           true <- digest(bytes) == upload.hash,
           {:ok, expected} <- revision(upload.path),
           true <- expected == upload.expected,
           :ok <- fs(upload.path, :write, [bytes]) do
        {:ok, upload.hash}
      else
        _ ->
          {:error,
           "Transfer failed validation or destination changed. Existing contents were preserved."}
      end

    {result, remaining}
  end

  defp dispatch(%{"op" => "cancel", "id" => id}, state), do: {:ok, Map.delete(state, id)}

  defp dispatch(%{"op" => "read", "path" => path, "offset" => offset}, state)
       when is_integer(offset) and offset >= 0 do
    result =
      with {:ok, bytes} <- read(path), true <- offset <= byte_size(bytes) do
        count = min(@chunk, byte_size(bytes) - offset)

        {:ok,
         %{
           "data" => Base.encode64(binary_part(bytes, offset, count)),
           "size" => byte_size(bytes),
           "hash" => digest(bytes)
         }}
      else
        false -> {:error, "Invalid transfer offset."}
        error -> error
      end

    {result, state}
  end

  defp dispatch(%{"op" => "list", "path" => path}, state) do
    result =
      with :ok <- valid(path),
           {:ok, entries} <- fs(path, :ls, []),
           true <- length(entries) <= @entries do
        {:ok,
         Enum.map(entries, fn entry ->
           %{"name" => entry.name, "type" => type(entry.type), "size" => entry.size}
         end)}
      else
        false -> {:error, "Folder contains too many entries."}
        error -> error
      end

    {result, state}
  end

  defp dispatch(%{"op" => "stat", "path" => path}, state) do
    result =
      with :ok <- valid(path),
           {:ok, entry} <- fs(path, :stat, []),
           do: {:ok, %{"type" => type(entry.type), "size" => entry.size}}

    {result, state}
  end

  defp dispatch(%{"op" => "revision", "path" => path}, state), do: {revision(path), state}

  defp dispatch(%{"op" => "mkdir", "path" => path}, state) do
    result = with :ok <- mutable(path), do: fs(path, :mkdir, [])
    {result, state}
  end

  defp dispatch(%{"op" => "remove", "path" => path, "expected" => expected}, state) do
    result =
      with :ok <- mutable(path) do
        case fs(path, :stat, []) do
          {:ok, %{type: :dir}} when expected == "empty_directory" ->
            fs(path, :rm, [])

          {:ok, %{type: :file}} ->
            case revision(path) do
              {:ok, ^expected} -> fs(path, :rm, [])
              _ -> {:error, "File changed. Refresh before deleting."}
            end

          _ ->
            {:error, "Confirm the current file or an empty folder before deleting."}
        end
      end

    {result, state}
  end

  defp dispatch(%{"op" => "rename", "path" => from, "to" => to}, state) do
    result =
      with :ok <- mutable(from),
           :ok <- mutable(to),
           true <- not String.starts_with?(to, from <> "/"),
           {:error, :enoent} <- fs(to, :stat, []) do
        rename(from, to)
      else
        {:ok, _} -> {:error, "Destination already exists."}
        false -> {:error, "Cannot move a folder inside itself."}
        error -> error
      end

    {result, state}
  end

  defp dispatch(_, state), do: {{:error, "Unsupported file request."}, state}

  defp read(path) do
    with :ok <- valid(path),
         {:ok, %{type: :file, size: size}} when size <= @max_file <- fs(path, :stat, []),
         {:ok, bytes} <- fs(path, :read, []),
         true <- byte_size(bytes) <= @max_file do
      {:ok, bytes}
    else
      {:ok, _} -> {:error, "Choose a regular file no larger than 16 MiB."}
      false -> {:error, "File exceeds the transfer limit."}
      error -> error
    end
  end

  defp revision(path) do
    case read(path) do
      {:ok, bytes} -> {:ok, digest(bytes)}
      {:error, :enoent} -> {:ok, "missing"}
      error -> error
    end
  end

  defp type(:file), do: "regular"
  defp type(:dir), do: "directory"
  defp type(_), do: "unavailable"
  defp digest(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
  defp now, do: System.monotonic_time(:millisecond)
  defp message(reason) when is_binary(reason), do: reason
  defp message(reason) when is_atom(reason), do: reason |> :file.format_error() |> to_string()
  defp message(_), do: "Filesystem operation failed."

  defp valid("/"), do: :ok

  defp valid("/" <> path) do
    if Enum.all?(String.split(path, "/"), &(&1 not in ["", ".", ".."])) and
         not String.contains?(path, ["\\", <<0>>]),
       do: :ok,
       else: {:error, "Invalid filesystem path."}
  end

  defp valid(_), do: {:error, "Choose an absolute filesystem path."}

  defp mutable(path) do
    with :ok <- valid(path) do
      if path in ["/", "/node"] or Regex.match?(~r{^/node/[^/]+/?$}, path),
        do: {:error, "Cannot change a filesystem root."},
        else: :ok
    end
  end

  defp fs("/node", :ls, []), do: SSI.FS.Node.ls("/")
  defp fs("/node", :stat, []), do: {:ok, %{type: :dir, size: 0}}

  defp fs("/node/" <> rest, operation, args) do
    [host | parts] = String.split(rest, "/")
    node = SSI.Proc.resolve_node(host)

    :erpc.call(
      node,
      __MODULE__,
      :node_request,
      [operation, "/" <> Enum.join(parts, "/"), args],
      15_000
    )
  end

  defp fs(path, :write, [bytes]), do: SSI.FS.Cluster.write(path, bytes, :write)
  defp fs(path, operation, args), do: apply(SSI.FS.Cluster, operation, [path | args])

  defp rename("/node/" <> a, "/node/" <> b) do
    [host | from] = String.split(a, "/")

    case String.split(b, "/") do
      [^host | to] ->
        :erpc.call(
          SSI.Proc.resolve_node(host),
          __MODULE__,
          :node_request,
          [:rename, "/" <> Enum.join(from, "/"), ["/" <> Enum.join(to, "/")]],
          15_000
        )

      _ ->
        {:error, "Use Copy to transfer files between nodes."}
    end
  end

  defp rename("/node/" <> _, _), do: {:error, "Use Copy to transfer files between locations."}
  defp rename(_, "/node/" <> _), do: {:error, "Use Copy to transfer files between locations."}
  defp rename(from, to), do: SSI.FS.Cluster.rename(from, to)

  @doc false
  def node_request(operation, path, args) do
    with :ok <- valid(path), {:ok, real} <- node_path(path) do
      case {operation, args} do
        {:ls, []} ->
          with {:ok, names} <- File.ls(real), true <- length(names) <= @entries do
            {:ok,
             Enum.map(names, fn name ->
               case node_request(:stat, Path.join(path, name), []) do
                 {:ok, entry} -> Map.put(entry, :name, name)
                 _ -> %{name: name, type: :unavailable, size: 0}
               end
             end)}
          else
            false -> {:error, "Folder contains too many entries."}
            error -> error
          end

        {:stat, []} ->
          with {:ok, info} <- File.lstat(real),
               do:
                 {:ok,
                  %{type: if(info.type == :directory, do: :dir, else: :file), size: info.size}}

        {:read, []} ->
          with {:ok, %{type: :regular, size: size}} when size <= @max_file <- File.lstat(real),
               {:ok, io} <- File.open(real, [:read, :binary]) do
            try do
              case IO.binread(io, @max_file + 1) do
                :eof -> {:ok, ""}
                bytes when is_binary(bytes) and byte_size(bytes) <= @max_file -> {:ok, bytes}
                _ -> {:error, :efbig}
              end
            after
              File.close(io)
            end
          else
            {:ok, _} -> {:error, :efbig}
            error -> error
          end

        {:write, [bytes]} when is_binary(bytes) and byte_size(bytes) <= @max_file ->
          temporary =
            real <> ".ssi-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)

          try do
            with :ok <- File.write(temporary, bytes, [:binary, :exclusive, :sync]),
                 do: File.rename(temporary, real)
          after
            File.rm(temporary)
          end

        {:mkdir, []} ->
          File.mkdir(real)

        {:rm, []} ->
          case File.lstat(real) do
            {:ok, %{type: :directory}} -> File.rmdir(real)
            {:ok, %{type: :regular}} -> File.rm(real)
            error -> error
          end

        {:rename, [destination]} ->
          with :ok <- valid(destination),
               {:ok, target} <- node_path(destination),
               {:error, :enoent} <- File.lstat(target),
               do: File.rename(real, target),
               else: (
                 {:ok, _} -> {:error, :eexist}
                 error -> error
               )

        _ ->
          {:error, :einval}
      end
    end
  end

  defp node_path(path) do
    root = if SSI.Sys.target?(), do: "/", else: Path.join(SSI.Boot.data_dir(), "root")
    real = if path == "/", do: root, else: Path.join(root, String.trim_leading(path, "/"))
    [anchor | parts] = Path.split(real)

    Enum.reduce_while(parts, {:ok, anchor}, fn part, {:ok, parent} ->
      next = Path.join(parent, part)

      case File.lstat(next) do
        {:ok, %{type: type}} when type in [:directory, :regular] -> {:cont, {:ok, next}}
        {:error, :enoent} -> {:cont, {:ok, next}}
        {:ok, _} -> {:halt, {:error, "Symlinks and special devices are not workspace files."}}
        error -> {:halt, error}
      end
    end)
  end
end
