defmodule ElixirSSI.Command.ProjectArchive do
  @moduledoc "Portable project ZIP import/export with validated paths and bounded expansion."
  alias ElixirSSI.Command.{LocalFiles, Projects}
  @excluded ["_build", "deps", ".git", ".tools", ".ssi-deployment.json"]

  def export(project) do
    with {:ok, root} <- Projects.safe_path(project, ""),
         {:ok, entries, _} <- collect(root, "", [], 0),
         {:ok, {_, zip}} <- :zip.create(~c"project.zip", entries, [:memory]) do
      {:ok, zip}
    end
  end

  defp collect(root, relative, acc, total) do
    with {:ok, entries} <- LocalFiles.list(root, relative) do
      Enum.reduce_while(entries, {:ok, acc, total}, fn entry, {:ok, files, size} ->
        result =
          cond do
            entry.name in @excluded ->
              {:ok, files, size}

            length(files) >= LocalFiles.limits().entries ->
              {:error, "Project has too many files."}

            entry.type == :directory ->
              collect(
                root,
                entry.path,
                [{String.to_charlist(entry.path <> "/"), ""} | files],
                size
              )

            entry.type == :regular ->
              with {:ok, bytes} <- LocalFiles.read(root, entry.path),
                   true <- size + byte_size(bytes) <= LocalFiles.limits().tree do
                {:ok, [{String.to_charlist(entry.path), bytes} | files], size + byte_size(bytes)}
              else
                false -> {:error, "Project exceeds the export limit."}
                error -> error
              end

            true ->
              {:error, "Project contains a symlink or unsupported file."}
          end

        case result do
          {:ok, _, _} -> {:cont, result}
          error -> {:halt, error}
        end
      end)
    end
  end

  def import(project, archive) when is_binary(archive) do
    with true <- byte_size(archive) <= LocalFiles.limits().tree,
         {:ok, destination} <- Projects.safe_path(project, ""),
         {:error, :enoent} <- File.lstat(destination),
         {:ok, entries} <- unpack(archive),
         true <- Enum.any?(entries, fn {name, _} -> name == "mix.exs" end) do
      :global.trans({{__MODULE__, destination}, self()}, fn ->
        stage =
          Path.join(
            Projects.root(),
            ".import-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
          )

        File.mkdir!(stage)

        try do
          with :ok <- write_entries(stage, entries),
               {:error, :enoent} <- File.lstat(destination),
               :ok <- File.rename(stage, destination) do
            {:ok, "Imported #{project}."}
          else
            {:ok, _} -> {:error, "Project already exists."}
            error -> error
          end
        after
          File.rm_rf(stage)
        end
      end)
    else
      false -> {:error, "Choose a bounded project ZIP with mix.exs at its root."}
      {:ok, _} -> {:error, "Project already exists."}
      error -> error
    end
  end

  defp unpack(archive) do
    result =
      :zip.foldl(
        fn name, info_fun, binary_fun, {entries, names, total} ->
          raw = List.to_string(name)
          directory? = String.ends_with?(raw, "/")
          path = if directory?, do: String.trim_trailing(raw, "/"), else: raw
          info = File.Stat.from_record(info_fun.())

          with true <- path != "" and length(entries) < LocalFiles.limits().entries,
               {:ok, _} <- LocalFiles.path("/archive", path),
               false <- MapSet.member?(names, String.downcase(path)),
               true <- info.type in [:regular, :directory],
               true <- info.size <= LocalFiles.limits().file,
               true <- total + info.size <= LocalFiles.limits().tree,
               false <- Enum.any?(String.split(path, "/"), &(&1 in @excluded)) do
            bytes = if directory?, do: :directory, else: binary_fun.()

            if is_binary(bytes) and byte_size(bytes) != info.size,
              do: throw({:archive_error, "ZIP entry size does not match its contents."})

            {[{path, bytes} | entries], MapSet.put(names, String.downcase(path)),
             total + info.size}
          else
            _ ->
              throw(
                {:archive_error,
                 "ZIP contains unsafe, duplicate, generated or oversized entries."}
              )
          end
        end,
        {[], MapSet.new(), 0},
        {~c"project.zip", archive}
      )

    case result do
      {:ok, {entries, _, _}} -> {:ok, Enum.reverse(entries)}
      _ -> {:error, "Cannot read this project ZIP."}
    end
  catch
    {:archive_error, message} -> {:error, message}
  end

  defp write_entries(root, entries) do
    Enum.reduce_while(entries, :ok, fn {name, bytes}, :ok ->
      result =
        if bytes == :directory do
          with {:ok, path} <- LocalFiles.path(root, name), do: File.mkdir_p(path)
        else
          LocalFiles.write(root, name, bytes)
        end

      case result do
        :ok -> {:cont, :ok}
        {:ok, _} -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end
end
