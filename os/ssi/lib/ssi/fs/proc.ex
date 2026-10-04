defmodule SSI.FS.Proc do
  @moduledoc """
  `/proc`: the live cluster rendered as read-only text files.

      /proc/cluster              the aggregate machine
      /proc/services             cluster services and where they run
      /proc/store                replicated-store statistics
      /proc/nodes/HOST/info      hardware and software of one member
      /proc/nodes/HOST/load      its latest load sample
      /proc/nodes/HOST/net       its interfaces and counters
      /proc/nodes/HOST/devices   devices and the drivers bound to them
  """
  @behaviour SSI.FS

  @top ~w(cluster services store nodes)
  @node_files ~w(info load net devices)

  defp dir(name), do: %{name: name, type: :dir, size: 0, mtime: nil}
  defp file(name), do: %{name: name, type: :file, size: 0, mtime: nil}

  defp hosts, do: Enum.map(SSI.Cluster.members(), &SSI.Cluster.hostname/1)

  @impl true
  def ls("/"), do: {:ok, Enum.map(@top, &if(&1 == "nodes", do: dir(&1), else: file(&1)))}
  def ls("/nodes"), do: {:ok, Enum.map(hosts(), &dir/1)}

  def ls("/nodes/" <> host) do
    if host in hosts(), do: {:ok, Enum.map(@node_files, &file/1)}, else: {:error, :enoent}
  end

  def ls(path) do
    case stat(path) do
      {:ok, %{type: :file} = f} -> {:ok, [f]}
      _ -> {:error, :enoent}
    end
  end

  @impl true
  def stat("/"), do: {:ok, dir("proc")}
  def stat("/nodes"), do: {:ok, dir("nodes")}

  def stat(path) do
    case read(path) do
      {:ok, data} -> {:ok, %{file(Path.basename(path)) | size: byte_size(data)}}
      {:error, :eisdir} -> {:ok, dir(Path.basename(path))}
      error -> error
    end
  end

  @impl true
  def read("/cluster") do
    s = SSI.Cluster.summary()

    {:ok,
     """
     cluster:    #{s.cluster}
     nodes:      #{s.nodes}
     cores:      #{s.cores}
     schedulers: #{s.schedulers}
     memory:     #{SSI.Shell.Format.bytes(s.memory)}
     processes:  #{SSI.Proc.count()}
     members:    #{Enum.join(s.members, " ")}
     """}
  end

  def read("/services") do
    {:ok,
     SSI.Service.list()
     |> Enum.map_join("", fn s ->
       where = if s.node, do: SSI.Cluster.hostname(s.node), else: "(stopped)"
       "#{inspect(s.name)}\t#{inspect(s.module)}\t#{where}#{if s.pinned, do: " (pinned)"}\n"
     end)}
  end

  def read("/store"), do: {:ok, SSI.Store.stats() |> Enum.map_join("", fn {k, v} -> "#{k}: #{v}\n" end)}

  def read("/nodes/" <> rest) do
    case String.split(rest, "/") do
      [host] -> if host in hosts(), do: {:error, :eisdir}, else: {:error, :enoent}
      [host, f] when f in @node_files -> node_file(host, f)
      _ -> {:error, :enoent}
    end
  end

  def read(p) when p in ["/", "/nodes"], do: {:error, :eisdir}
  def read(_), do: {:error, :enoent}

  defp node_file(host, f) do
    node = SSI.Proc.resolve_node(host)

    text =
      case f do
        "info" -> SSI.Cluster.info(node) |> kv()
        "load" -> (SSI.Load.get(node) || %{}) |> Map.drop([:history]) |> kv()
        "net" -> :erpc.call(node, SSI.Net, :links, []) |> Enum.map_join("", &(kv(&1) <> "\n"))
        "devices" -> :erpc.call(node, SSI.Devices, :list, []) |> Enum.map_join("", &"#{&1.device}\t#{&1.module || "-"}\n")
      end

    {:ok, text}
  rescue
    ArgumentError -> {:error, :enoent}
  end

  defp kv(map), do: map |> Enum.sort() |> Enum.map_join("", fn {k, v} -> "#{k}: #{fmt(v)}\n" end)
  defp fmt(v) when is_binary(v), do: v
  defp fmt(v), do: inspect(v)

  @impl true
  def write(_, _, _), do: {:error, :erofs}
  @impl true
  def mkdir(_), do: {:error, :erofs}
  @impl true
  def rm(_), do: {:error, :erofs}
  @impl true
  def rename(_, _), do: {:error, :erofs}
end
