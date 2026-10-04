defmodule SSI.FS.Node do
  @moduledoc """
  `/node/HOST/...`: each member's own local filesystem.

  The cluster tree at `/` is shared; sometimes a user needs one machine's
  files specifically — its boot partition, its data disk, its kernel's
  `/sys`. Every operation is executed on that member with `:erpc`, so
  `/node/ssi-1a2b3c/boot/ssi.conf` reads the file on that Pi from any node.

  In hosted mode the local root is confined to the node's data directory.
  """
  @behaviour SSI.FS

  defp dir(name), do: %{name: name, type: :dir, size: 0, mtime: nil}

  defp split("/"), do: :root

  defp split("/" <> rest) do
    case String.split(rest, "/", parts: 2) do
      [host] -> {host, "/"}
      [host, path] -> {host, "/" <> path}
    end
  end

  defp on(host, fun, args) do
    node = SSI.Proc.resolve_node(host)
    :erpc.call(node, __MODULE__, fun, args, 15_000)
  rescue
    ArgumentError -> {:error, :enoent}
  catch
    :error, {:erpc, reason} -> {:error, reason}
  end

  @impl true
  def ls(path) do
    case split(path) do
      :root -> {:ok, Enum.map(SSI.Cluster.members(), &dir(SSI.Cluster.hostname(&1)))}
      {host, p} -> on(host, :local_ls, [p])
    end
  end

  @impl true
  def stat(path) do
    case split(path) do
      :root -> {:ok, dir("node")}
      {host, p} -> on(host, :local_stat, [p])
    end
  end

  @impl true
  def read(path), do: with({host, p} <- split(path), do: on(host, :local_read, [p])) |> root_error()
  @impl true
  def write(path, data, mode), do: with({host, p} <- split(path), do: on(host, :local_write, [p, data, mode])) |> root_error()
  @impl true
  def mkdir(path), do: with({host, p} <- split(path), do: on(host, :local_mkdir, [p])) |> root_error()
  @impl true
  def rm(path), do: with({host, p} <- split(path), do: on(host, :local_rm, [p])) |> root_error()

  @impl true
  def rename(from, to) do
    case {split(from), split(to)} do
      {{h, a}, {h, b}} -> on(h, :local_rename, [a, b])
      _ -> {:error, :exdev}
    end
  end

  defp root_error(:root), do: {:error, :eisdir}
  defp root_error(other), do: other

  # -- executed on the owning member -----------------------------------------

  defp real(p) do
    if SSI.Sys.target?(), do: p, else: Path.join([SSI.Boot.data_dir(), "root", p])
  end

  @doc false
  def local_ls(p) do
    with {:ok, names} <- File.ls(real(p)) do
      {:ok, Enum.flat_map(names, fn n -> case local_stat(Path.join(p, n)) do {:ok, e} -> [e]; _ -> [] end end)}
    end
  end

  @doc false
  def local_stat(p) do
    with {:ok, st} <- File.lstat(real(p), time: :posix) do
      type = if st.type == :directory, do: :dir, else: :file
      {:ok, %{name: Path.basename(p), type: type, size: st.size, mtime: st.mtime}}
    end
  end

  @doc false
  def local_read(p), do: File.read(real(p))

  @doc false
  def local_write(p, data, :write), do: File.write(real(p), data)
  def local_write(p, data, :append), do: File.write(real(p), data, [:append])

  @doc false
  def local_mkdir(p), do: File.mkdir(real(p))

  @doc false
  def local_rm(p) do
    case File.rm(real(p)) do
      {:error, :eisdir} -> File.rmdir(real(p))
      {:error, :eperm} -> File.rmdir(real(p))
      other -> other
    end
  end

  @doc false
  def local_rename(a, b), do: File.rename(real(a), real(b))
end
