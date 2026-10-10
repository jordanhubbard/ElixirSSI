defmodule ElixirSSI.Command.RemoteFiles do
  @moduledoc "Checksummed chunked file access over verified operator SSH connections."
  alias ElixirSSI.Command.{LocalFiles, Remote}
  @chunk 96 * 1024

  def call(target, base, operation, [relative | args]) do
    with {:ok, path} <- path(base, relative) do
      execute(target, base, path, relative, operation, args)
    end
  end

  defp path(base, relative) do
    with {:ok, _} <- LocalFiles.path("/workspace", relative) do
      {:ok,
       if(relative == "", do: base, else: String.trim_trailing(base, "/") <> "/" <> relative)}
    end
  end

  defp execute(target, _, path, relative, :list, []) do
    with {:ok, entries} <- rpc(target, %{op: "list", path: path}) do
      {:ok,
       Enum.map(entries, fn entry ->
         %{
           name: entry["name"],
           path: if(relative == "", do: entry["name"], else: relative <> "/" <> entry["name"]),
           type: type(entry["type"]),
           size: entry["size"]
         }
       end)}
    end
  end

  defp execute(target, _, path, relative, :stat, []) do
    with {:ok, info} <- rpc(target, %{op: "stat", path: path}),
         do: {:ok, %{path: relative, type: type(info["type"]), size: info["size"]}}
  end

  defp execute(target, _, path, _, :read, []), do: read(target, path, 0, nil, nil, [])

  defp execute(target, _, path, _, :revision, []) do
    case rpc(target, %{op: "revision", path: path}) do
      {:ok, "missing"} -> {:ok, :missing}
      result -> result
    end
  end

  defp execute(target, base, path, relative, :write, [bytes]),
    do: execute(target, base, path, relative, :write, [bytes, :missing])

  defp execute(target, _, path, _, :write, [bytes, expected]) when is_binary(bytes) do
    with true <- byte_size(bytes) <= LocalFiles.limits().file,
         {:ok, id} <-
           rpc(target, %{
             op: "begin",
             path: path,
             size: byte_size(bytes),
             hash: LocalFiles.digest(bytes),
             expected: expected
           }) do
      result = with :ok <- append(target, id, bytes, 0), do: rpc(target, %{op: "finish", id: id})
      if match?({:error, _}, result), do: rpc(target, %{op: "cancel", id: id})
      result
    else
      false -> {:error, "File exceeds the 16 MiB transfer limit."}
      error -> error
    end
  end

  defp execute(target, _, path, _, :mkdir, []), do: mutation(target, %{op: "mkdir", path: path})

  defp execute(target, _, path, _, :remove, [expected]),
    do: mutation(target, %{op: "remove", path: path, expected: expected})

  defp execute(target, base, path, _, :rename, [destination]) do
    with {:ok, to} <- path(base, destination),
         do: mutation(target, %{op: "rename", path: path, to: to})
  end

  defp execute(target, base, path, relative, :snapshot, []),
    do: execute(target, base, path, relative, :snapshot, [[]])

  defp execute(target, base, _, relative, :snapshot, [excluded]) do
    case walk(target, base, relative, %{}, 0, excluded) do
      {:ok, entries, _} -> {:ok, entries}
      error -> error
    end
  end

  defp execute(_, _, _, _, _, _), do: {:error, "Unsupported file operation."}
  defp type("directory"), do: :directory
  defp type("regular"), do: :regular
  defp type(_), do: :unavailable

  defp mutation(target, params) do
    case rpc(target, params) do
      {:ok, true} -> :ok
      error -> error
    end
  end

  defp read(target, path, offset, hash, size, chunks) do
    with {:ok, packet} <- rpc(target, %{op: "read", path: path, offset: offset}),
         true <- is_integer(packet["size"]) and packet["size"] <= LocalFiles.limits().file,
         true <- hash == nil or (packet["hash"] == hash and packet["size"] == size),
         {:ok, bytes} <- Base.decode64(packet["data"]),
         true <- byte_size(bytes) <= @chunk and offset + byte_size(bytes) <= packet["size"] do
      next = offset + byte_size(bytes)

      cond do
        next == packet["size"] ->
          all = [bytes | chunks] |> Enum.reverse() |> IO.iodata_to_binary()

          if LocalFiles.digest(all) == packet["hash"],
            do: {:ok, all},
            else: {:error, "Download checksum mismatch."}

        bytes == "" ->
          {:error, "Download ended before all bytes arrived."}

        true ->
          read(target, path, next, packet["hash"], packet["size"], [bytes | chunks])
      end
    else
      false -> {:error, "File changed during download or exceeded the transfer limit."}
      error -> error
    end
  end

  defp append(_, _, "", _), do: :ok

  defp append(target, id, bytes, offset) do
    count = min(@chunk, byte_size(bytes))
    <<chunk::binary-size(^count), rest::binary>> = bytes
    expected = offset + count

    with {:ok, ^expected} <-
           rpc(target, %{op: "append", id: id, offset: offset, data: Base.encode64(chunk)}),
         do: append(target, id, rest, expected),
         else: (
           {:ok, _} -> {:error, "Transfer offset mismatch."}
           error -> error
         )
  end

  defp walk(target, base, relative, acc, total, excluded) do
    with {:ok, entries} <- call(target, base, :list, [relative]) do
      Enum.reduce_while(entries, {:ok, acc, total}, fn entry, {:ok, files, size} ->
        result =
          cond do
            entry.name in excluded ->
              {:ok, files, size}

            map_size(files) >= LocalFiles.limits().entries ->
              {:error, "Tree contains too many entries."}

            entry.type == :directory ->
              walk(
                target,
                base,
                entry.path,
                Map.put(files, entry.path, %{type: :directory}),
                size,
                excluded
              )

            entry.type == :regular ->
              with {:ok, hash} <- call(target, base, :revision, [entry.path]),
                   true <- is_binary(hash) and size + entry.size <= LocalFiles.limits().tree,
                   do:
                     {:ok,
                      Map.put(files, entry.path, %{type: :regular, hash: hash, size: entry.size}),
                      size + entry.size},
                   else: (
                     false -> {:error, "Tree exceeds transfer limits or changed."}
                     error -> error
                   )

            true ->
              {:error, "Tree contains unsupported files or symlinks."}
          end

        case result do
          {:ok, _, _} -> {:cont, result}
          error -> {:halt, error}
        end
      end)
    end
  end

  def rpc(target, params, service \\ :files) do
    payload = params |> Jason.encode!() |> Base.encode64()

    module =
      case service do
        :files -> "SSI.WorkspaceFiles"
        :demos -> "SSI.Desktop.Sources"
      end

    source =
      "\"SSI_FILES:\" <> Base.encode64(JSON.encode!(#{module}.request(JSON.decode!(Base.decode64!(\"#{payload}\")))))"

    with {:ok, output} <- Remote.evaluate(target, source),
         [_, encoded] <- Regex.run(~r/^"SSI_FILES:([A-Za-z0-9+\/=]+)"\s*$/, output),
         {:ok, json} <- Base.decode64(encoded),
         {:ok, reply} <- Jason.decode(json) do
      case reply do
        %{"ok" => value} -> {:ok, value}
        %{"error" => message} -> {:error, message}
        _ -> {:error, "Invalid response from the node file service."}
      end
    else
      {:error, message} ->
        {:error, message}

      _ ->
        {:error, "Node file service unavailable. Upgrade the node image to use workspace files."}
    end
  end
end
