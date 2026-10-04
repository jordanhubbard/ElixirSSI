defmodule SSI.FS.Cluster do
  @moduledoc """
  The replicated cluster filesystem mounted at `/`.

  Metadata (type, size, mtime, mode, and the list of content chunks) lives in
  the `:fs` table of `SSI.Store`, so every node holds the whole tree and can
  list or stat any path locally. File content is split into 1 MiB chunks
  stored as content-addressed blobs (`SSI.Blob`), each on `replicas` nodes.
  Identical chunks are stored once. Writes are whole-file and
  last-writer-wins, in the tradition of a cluster object store rather than a
  POSIX block device.
  """
  use GenServer
  @behaviour SSI.FS

  @chunk 1_048_576
  @gc_ms 600_000
  @standard_dirs ~w(/home /srv /tmp /var /etc)

  def start_link(_), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @impl GenServer
  def init(_) do
    Process.send_after(self(), :standard_dirs, 3_000)
    Process.send_after(self(), :gc, @gc_ms)
    {:ok, %{}}
  end

  @impl GenServer
  def handle_info(:standard_dirs, state) do
    # Delayed so a joining node first learns the existing tree by anti-entropy.
    for dir <- @standard_dirs, SSI.Store.version(:fs, dir) == nil, do: mkdir(dir)
    {:noreply, state}
  end

  def handle_info(:gc, state) do
    referenced = SSI.Store.all(:fs) |> Enum.flat_map(fn {_, m} -> Map.get(m, :chunks, []) end) |> MapSet.new()
    SSI.Blob.gc_local(referenced)
    Process.send_after(self(), :gc, @gc_ms)
    {:noreply, state}
  end

  defp meta("/"), do: %{type: :dir, size: 0, mtime: nil}
  defp meta(path), do: SSI.Store.get(:fs, path)

  defp entry(path, m), do: Map.take(m, [:type, :size, :mtime, :origin]) |> Map.put(:name, Path.basename(path))

  @impl SSI.FS
  def stat(path) do
    case meta(path) do
      nil -> {:error, :enoent}
      m -> {:ok, entry(path, m)}
    end
  end

  @impl SSI.FS
  def ls(path) do
    case meta(path) do
      %{type: :dir} ->
        {:ok, for({p, m} <- SSI.Store.all(:fs), Path.dirname(p) == path and p != "/", do: entry(p, m))}

      nil ->
        {:error, :enoent}

      m ->
        {:ok, [entry(path, m)]}
    end
  end

  @impl SSI.FS
  def read(path) do
    case meta(path) do
      %{type: :file, chunks: chunks} ->
        Enum.reduce_while(chunks, {:ok, []}, fn h, {:ok, acc} ->
          case SSI.Blob.get(h) do
            {:ok, data} -> {:cont, {:ok, [acc, data]}}
            error -> {:halt, error}
          end
        end)
        |> case do
          {:ok, iodata} -> {:ok, IO.iodata_to_binary(iodata)}
          error -> error
        end

      %{type: :dir} ->
        {:error, :eisdir}

      nil ->
        {:error, :enoent}
    end
  end

  @impl SSI.FS
  def write(path, data, mode) do
    data = IO.iodata_to_binary(data)

    with :ok <- parent_dir(path),
         {:ok, existing} <- existing_for(path, mode) do
      content = existing <> data

      with {:ok, hashes} <- store_chunks(chunk(content)) do
        SSI.Store.put(:fs, path, %{
          type: :file,
          size: byte_size(content),
          chunks: hashes,
          mtime: System.os_time(:second),
          mode: 0o644,
          origin: SSI.Boot.hostname()
        })
      end
    end
  end

  defp chunk(<<c::binary-size(@chunk), rest::binary>>) when rest != "", do: [c | chunk(rest)]
  defp chunk(c), do: [c]

  defp store_chunks(chunks) do
    Enum.reduce_while(chunks, {:ok, []}, fn c, {:ok, acc} ->
      case SSI.Blob.put(c) do
        {:ok, h} -> {:cont, {:ok, [h | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, hs} -> {:ok, Enum.reverse(hs)}
      error -> error
    end
  end

  defp existing_for(_path, :write), do: {:ok, ""}

  defp existing_for(path, :append) do
    case read(path) do
      {:ok, data} -> {:ok, data}
      {:error, :enoent} -> {:ok, ""}
      error -> error
    end
  end

  defp parent_dir(path) do
    case meta(Path.dirname(path)) do
      %{type: :dir} -> if meta(path)[:type] == :dir, do: {:error, :eisdir}, else: :ok
      nil -> {:error, :enoent}
      _ -> {:error, :enotdir}
    end
  end

  @impl SSI.FS
  def mkdir("/"), do: {:error, :eexist}

  def mkdir(path) do
    cond do
      meta(path) != nil -> {:error, :eexist}
      meta(Path.dirname(path))[:type] != :dir -> {:error, :enoent}
      true -> SSI.Store.put(:fs, path, %{type: :dir, size: 0, mtime: System.os_time(:second), origin: SSI.Boot.hostname()})
    end
  end

  @impl SSI.FS
  def rm("/"), do: {:error, :eperm}

  def rm(path) do
    case meta(path) do
      nil ->
        {:error, :enoent}

      %{type: :dir} ->
        if Enum.any?(SSI.Store.keys(:fs), &(Path.dirname(&1) == path)),
          do: {:error, :enotempty},
          else: SSI.Store.delete(:fs, path)

      _ ->
        SSI.Store.delete(:fs, path)
    end
  end

  @impl SSI.FS
  def rename(from, to) do
    with m when m != nil <- meta(from) || {:error, :enoent},
         :ok <- parent_dir(to) do
      moved =
        for {p, pm} <- SSI.Store.all(:fs), p == from or String.starts_with?(p, from <> "/") do
          {to <> String.replace_prefix(p, from, ""), pm}
        end

      :ok = SSI.Store.put_many(:fs, moved)
      Enum.each(moved, fn {p, _} -> SSI.Store.delete(:fs, from <> String.replace_prefix(p, to, "")) end)
    end
  end
end
