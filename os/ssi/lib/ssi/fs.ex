defmodule SSI.FS do
  @moduledoc """
  The single filesystem namespace every node presents.

      /            cluster filesystem: one tree, replicated (SSI.FS.Cluster)
      /proc        the running cluster as files (SSI.FS.Proc)
      /node/HOST   each member's own local filesystem (SSI.FS.Node)

  Paths are resolved against a per-process working directory, so every shell
  session has its own `cd`. A file written on one node is immediately listed
  and readable on every other: the namespace does not depend on where you are.
  """

  @mounts [{"/proc", SSI.FS.Proc}, {"/node", SSI.FS.Node}, {"/", SSI.FS.Cluster}]

  @type entry :: %{name: String.t(), type: :file | :dir, size: non_neg_integer(), mtime: integer() | nil}

  @callback ls(String.t()) :: {:ok, [entry]} | {:error, atom}
  @callback stat(String.t()) :: {:ok, entry} | {:error, atom}
  @callback read(String.t()) :: {:ok, binary} | {:error, atom}
  @callback write(String.t(), iodata, :write | :append) :: :ok | {:error, atom}
  @callback mkdir(String.t()) :: :ok | {:error, atom}
  @callback rm(String.t()) :: :ok | {:error, atom}
  @callback rename(String.t(), String.t()) :: :ok | {:error, atom}

  def cwd, do: Process.get(:ssi_cwd, "/")

  def cd(path) do
    abs = expand(path)

    case stat(abs) do
      {:ok, %{type: :dir}} ->
        Process.put(:ssi_cwd, abs)
        :ok

      {:ok, _} -> {:error, :enotdir}
      error -> error
    end
  end

  @doc "Absolute, normalised form of `path` relative to the working directory."
  def expand(path) do
    path = to_string(path)
    base = if String.starts_with?(path, "/"), do: path, else: Path.join(cwd(), path)

    base
    |> String.split("/", trim: true)
    |> Enum.reduce([], fn
      ".", acc -> acc
      "..", [] -> []
      "..", [_ | acc] -> acc
      seg, acc -> [seg | acc]
    end)
    |> Enum.reverse()
    |> then(&("/" <> Enum.join(&1, "/")))
  end

  @doc "The backend owning `path` and the path relative to its mount point."
  def resolve(path) do
    abs = expand(path)

    Enum.find_value(@mounts, fn {mount, mod} ->
      cond do
        mount == "/" -> {mod, abs}
        abs == mount -> {mod, "/"}
        String.starts_with?(abs, mount <> "/") -> {mod, String.replace_prefix(abs, mount, "")}
        true -> nil
      end
    end)
  end

  def ls(path \\ ".") do
    {mod, rel} = resolve(path)

    with {:ok, entries} <- mod.ls(rel) do
      extra = if expand(path) == "/", do: mount_points(), else: []
      {:ok, Enum.sort_by(Enum.uniq_by(extra ++ entries, & &1.name), & &1.name)}
    end
  end

  defp mount_points do
    for name <- ["proc", "node"], do: %{name: name, type: :dir, size: 0, mtime: nil}
  end

  def stat(path), do: dispatch(path, :stat, [])
  def read(path), do: dispatch(path, :read, [])
  def write(path, data), do: dispatch(path, :write, [data, :write])
  def append(path, data), do: dispatch(path, :append_write, [data])
  def mkdir(path), do: dispatch(path, :mkdir, [])
  def rm(path), do: dispatch(path, :rm, [])

  def exists?(path), do: match?({:ok, _}, stat(path))
  def dir?(path), do: match?({:ok, %{type: :dir}}, stat(path))

  def mkdir_p(path) do
    abs = expand(path)

    abs
    |> String.split("/", trim: true)
    |> Enum.scan("", &(&2 <> "/" <> &1))
    |> Enum.reduce_while(:ok, fn dir, _ ->
      case stat(dir) do
        {:ok, %{type: :dir}} -> {:cont, :ok}
        {:ok, _} -> {:halt, {:error, :enotdir}}
        _ -> if (r = mkdir(dir)) == :ok, do: {:cont, :ok}, else: {:halt, r}
      end
    end)
  end

  def rm_rf(path) do
    case stat(path) do
      {:ok, %{type: :dir}} ->
        {:ok, entries} = ls(path)
        Enum.each(entries, &rm_rf(Path.join(expand(path), &1.name)))
        rm(path)

      {:ok, _} ->
        rm(path)

      error ->
        error
    end
  end

  def rename(from, to) do
    {m1, r1} = resolve(from)
    {m2, r2} = resolve(to)

    if m1 == m2 do
      m1.rename(r1, r2)
    else
      # Across mounts a rename is a copy followed by a delete.
      with {:ok, data} <- read(from), :ok <- write(to, data), do: rm(from)
    end
  end

  def cp(from, to) do
    with {:ok, data} <- read(from) do
      target = if dir?(to), do: Path.join(expand(to), Path.basename(expand(from))), else: to
      write(target, data)
    end
  end

  defp dispatch(path, :append_write, [data]) do
    {mod, rel} = resolve(path)
    mod.write(rel, data, :append)
  end

  defp dispatch(path, fun, args) do
    {mod, rel} = resolve(path)
    apply(mod, fun, [rel | args])
  end
end
