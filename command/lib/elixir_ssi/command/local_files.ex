defmodule ElixirSSI.Command.LocalFiles do
  @moduledoc "Bounded workspace file operations with explicit overwrite identities."
  @max_file 16 * 1024 * 1024
  @max_entries 2000
  @max_tree 64 * 1024 * 1024

  def limits, do: %{file: @max_file, entries: @max_entries, tree: @max_tree}

  def path(root, relative) when is_binary(root) and is_binary(relative) do
    parts = String.split(relative, "/", trim: false)

    if Path.type(root) == :absolute and Path.type(relative) == :relative and
         not String.contains?(relative, ["\\", <<0>>]) and
         (relative == "" or Enum.all?(parts, &valid_segment?/1)) do
      absolute = Path.join(root, relative)
      [anchor | segments] = Path.split(absolute)

      segments
      |> Enum.reduce_while(anchor, fn part, parent ->
        candidate = Path.join(parent, part)

        case File.lstat(candidate) do
          {:ok, %{type: :symlink}} -> {:halt, {:error, "Symlinks are not workspace paths."}}
          {:ok, %{type: type}} when type in [:regular, :directory] -> {:cont, candidate}
          {:error, :enoent} -> {:cont, candidate}
          _ -> {:halt, {:error, "Unsupported or inaccessible workspace path."}}
        end
      end)
      |> case do
        value when is_binary(value) -> {:ok, value}
        error -> error
      end
    else
      {:error, "Choose a relative path inside the selected folder."}
    end
  end

  def path(_, _), do: {:error, "Invalid workspace path."}

  defp valid_segment?(part) do
    part not in ["", ".", ".."] and
      not String.contains?(part, ["<", ">", ":", "\"", "|", "?", "*"]) and
      not String.ends_with?(part, [".", " "]) and
      not Regex.match?(~r/^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(\.|$)/i, part)
  end

  def list(root, relative \\ "") do
    with {:ok, directory} <- path(root, relative),
         {:ok, names} <- File.ls(directory),
         true <- length(names) <= @max_entries do
      names
      |> Enum.sort()
      |> Enum.reduce_while({:ok, []}, fn name, {:ok, entries} ->
        child = if relative == "", do: name, else: relative <> "/" <> name

        case stat(root, child) do
          {:ok, entry} ->
            {:cont, {:ok, [Map.put(entry, :name, name) | entries]}}

          {:error, _} ->
            {:cont, {:ok, [%{name: name, path: child, type: :unavailable, size: 0} | entries]}}
        end
      end)
      |> case do
        {:ok, entries} -> {:ok, Enum.reverse(entries)}
        error -> error
      end
    else
      false -> {:error, "Folder contains too many entries."}
      error -> error
    end
  end

  def stat(root, relative) do
    with {:ok, filename} <- path(root, relative),
         {:ok, info} <- File.lstat(filename) do
      {:ok, %{path: relative, type: info.type, size: info.size}}
    end
  end

  def read(root, relative) do
    with {:ok, filename} <- path(root, relative),
         {:ok, %{type: :regular, size: size}} when size <= @max_file <- File.lstat(filename),
         {:ok, io} <- File.open(filename, [:read, :binary]) do
      try do
        case IO.binread(io, @max_file + 1) do
          :eof -> {:ok, ""}
          bytes when is_binary(bytes) and byte_size(bytes) <= @max_file -> {:ok, bytes}
          _ -> {:error, "File exceeds the transfer limit."}
        end
      after
        File.close(io)
      end
    else
      {:ok, _} -> {:error, "Choose a regular file within the transfer limit."}
      error -> error
    end
  end

  def digest(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  def revision(root, relative) do
    case read(root, relative) do
      {:ok, bytes} -> {:ok, digest(bytes)}
      {:error, :enoent} -> {:ok, :missing}
      error -> error
    end
  end

  def write(root, relative, bytes, expected \\ :missing)

  def write(root, relative, bytes, expected)
      when is_binary(bytes) and byte_size(bytes) <= @max_file and relative != "" do
    locked(root, fn ->
      with {:ok, filename} <- path(root, relative),
           {:ok, ^expected} <- revision(root, relative),
           :ok <- File.mkdir_p(Path.dirname(filename)) do
        temporary =
          filename <> ".ssi-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)

        try do
          with :ok <- File.write(temporary, bytes, [:binary, :exclusive]),
               :ok <- File.rename(temporary, filename),
               do: {:ok, digest(bytes)}
        after
          File.rm(temporary)
        end
      else
        {:ok, _} -> {:error, "Destination changed. Refresh and confirm the overwrite."}
        error -> error
      end
    end)
  end

  def write(_, _, _, _), do: {:error, "File exceeds the transfer limit or path is empty."}

  def mkdir(root, relative) when relative != "" do
    locked(root, fn ->
      with {:ok, directory} <- path(root, relative), do: File.mkdir(directory)
    end)
  end

  def mkdir(_, _), do: {:error, "Cannot replace the workspace root."}

  def rename(root, from, to) when from != "" and to != "" do
    locked(root, fn ->
      with {:ok, source} <- path(root, from),
           {:ok, destination} <- path(root, to),
           {:error, :enoent} <- File.lstat(destination),
           do: File.rename(source, destination),
           else: (
             {:ok, _} -> {:error, "Destination already exists."}
             error -> error
           )
    end)
  end

  def rename(_, _, _), do: {:error, "Cannot rename the workspace root."}

  def remove(root, relative, expected) when relative != "" do
    locked(root, fn ->
      with {:ok, filename} <- path(root, relative) do
        case {File.lstat(filename), expected} do
          {{:ok, %{type: :directory}}, :empty_directory} ->
            File.rmdir(filename)

          {{:ok, %{type: :regular}}, hash} ->
            with {:ok, ^hash} <- revision(root, relative),
                 do: File.rm(filename),
                 else: (
                   {:ok, _} -> {:error, "File changed. Refresh before deleting."}
                   error -> error
                 )

          _ ->
            {:error, "Confirm the current file or an empty folder before deleting."}
        end
      end
    end)
  end

  def remove(_, _, _), do: {:error, "Cannot remove the workspace root."}

  def snapshot(root, relative \\ "", excluded \\ []) do
    walk(root, relative, %{}, 0, excluded)
    |> case do
      {:ok, entries, _} -> {:ok, entries}
      error -> error
    end
  end

  defp walk(root, relative, entries, size, excluded) do
    with {:ok, children} <- list(root, relative) do
      Enum.reduce_while(children, {:ok, entries, size}, fn child, {:ok, acc, total} ->
        result =
          cond do
            child.name in excluded ->
              {:ok, acc, total}

            map_size(acc) >= @max_entries ->
              {:error, "Tree contains too many entries."}

            child.type == :directory ->
              walk(
                root,
                child.path,
                Map.put(acc, child.path, %{type: :directory}),
                total,
                excluded
              )

            child.type == :regular ->
              with {:ok, bytes} <- read(root, child.path),
                   true <- total + byte_size(bytes) <= @max_tree do
                {:ok,
                 Map.put(acc, child.path, %{
                   type: :regular,
                   hash: digest(bytes),
                   size: byte_size(bytes)
                 }), total + byte_size(bytes)}
              else
                false -> {:error, "Tree exceeds the transfer limit."}
                error -> error
              end

            true ->
              {:error, "Tree contains unsupported paths or symlinks."}
          end

        case result do
          {:ok, _, _} -> {:cont, result}
          error -> {:halt, error}
        end
      end)
    end
  end

  defp locked(root, fun), do: :global.trans({{__MODULE__, root}, self()}, fun)
end
