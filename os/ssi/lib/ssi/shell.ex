defmodule SSI.Shell do
  @moduledoc """
  The system shell: IEx, with these commands imported.

  Every console and SSH session on every node is an Elixir shell over the same
  single system image, so a command means the same thing wherever it is typed:
  `ps` lists the cluster's processes, `ls /` lists the cluster's files, and
  `run` executes on whichever machine is least busy. Type `help` for a summary.
  Anything else is ordinary Elixir — the shell *is* the system programming
  language.
  """
  alias SSI.Shell.Format

  @quiet :"do not show this result in output"

  @doc false
  def dot_iex do
    """
    import IEx.Helpers, except: [ls: 0, ls: 1, cd: 1, pwd: 0]
    import SSI.Shell
    IEx.configure(
      default_prompt: "#{SSI.Boot.hostname()}(%counter)>",
      alive_prompt: "#{SSI.Boot.hostname()}(%counter)>",
      history_size: 200
    )
    """
  end

  @doc "The banner shown on consoles and SSH logins."
  def motd do
    s = SSI.Cluster.summary()

    insecure =
      if SSI.Config.insecure_secret?(),
        do: "\n  WARNING: default cluster secret in use; set ssi.secret before networking untrusted hosts.",
        else: ""

    """

      ElixirSSI #{Application.spec(:ssi, :vsn)} - Elixir #{System.version()} on Erlang/OTP #{System.otp_release()}
      #{SSI.Boot.hostname()} (#{node()}) in cluster "#{s.cluster}": #{s.nodes} node(s), #{s.cores} cores, #{Format.bytes(s.memory)}#{insecure}
      Type help for system commands. The shell is Elixir.
    """
  end

  def help do
    IO.puts("""
    Cluster      nodes  cluster  uptime  free  df  services  dmesg(host \\\\ local)
    Processes    ps(name: "x", node: host)  top(n)  kill(pid)  pinfo(pid)
    Placement    run(fun)  on(host, fun)  pmap(enum, fun)  spawn_anywhere(fun)
    Files        ls(p)  cd(p)  pwd  cat(p)  write(p, data)  append(p, data)
                 mkdir(p)  rm(p)  rm_rf(p)  mv(a, b)  cp(a, b)  tree(p)
                 /  shared tree   /proc  live cluster   /node/HOST  a machine's own disk
    Services     services  migrate(name, host)  register_service(name, module, args)
    Demos        mandel  bench(n)  desktop(host_port)
    Power        reboot(:all | host)  poweroff(:all | host)
    Monitor      monitor_pair(name)  monitor_keys  monitor_revoke(id_or_name)  monitor_ca
    PIDs print as HOST:<0.123.0>; pass that string to kill/pinfo from any node.
    """)

    @quiet
  end

  # -- cluster ----------------------------------------------------------------

  def nodes do
    rows =
      for info <- SSI.Cluster.infos() do
        load = SSI.Load.get(info.node) || %{}

        [
          info.hostname,
          info[:ip],
          info.cores,
          Format.bytes(info.memory),
          Format.percent(load[:util]),
          load[:processes],
          load[:temperature] && "#{load[:temperature]}C",
          info[:model]
        ]
      end

    IO.write(Format.table(~w(HOST ADDRESS CORES MEMORY LOAD PROCS TEMP MODEL), rows))
    @quiet
  end

  def cluster do
    {:ok, text} = SSI.FS.read("/proc/cluster")
    IO.write(text)
    @quiet
  end

  def uptime do
    for info <- SSI.Cluster.infos() do
      up = System.os_time(:second) - (info[:booted_at] || System.os_time(:second))
      IO.puts("#{String.pad_trailing(info.hostname, 16)} up #{Format.duration(up)}")
    end

    @quiet
  end

  def free do
    rows =
      for s <- SSI.Load.cluster() do
        used = s.mem_total - s.mem_available
        [SSI.Cluster.hostname(s.node), Format.bytes(s.mem_total), Format.bytes(used), Format.bytes(s.mem_available), Format.bytes(s.beam_memory)]
      end

    totals = SSI.Load.cluster() |> Enum.reduce({0, 0}, fn s, {t, a} -> {t + s.mem_total, a + s.mem_available} end)
    rows = rows ++ [["TOTAL", Format.bytes(elem(totals, 0)), Format.bytes(elem(totals, 0) - elem(totals, 1)), Format.bytes(elem(totals, 1)), ""]]
    IO.write(Format.table(~w(HOST TOTAL USED AVAILABLE BEAM), rows))
    @quiet
  end

  def df do
    rows =
      for n <- SSI.Cluster.members() do
        {disk, blobs} =
          :erpc.call(n, fn ->
            {SSI.Sys.statvfs(SSI.Boot.data_dir()), SSI.Blob.local_stats()}
          end)

        {size, avail} =
          case disk do
            {:ok, {bs, blocks, _free, av}} -> {bs * blocks, bs * av}
            _ -> {nil, nil}
          end

        [SSI.Cluster.hostname(n), Format.bytes(size), Format.bytes(avail), blobs.blobs, Format.bytes(blobs.bytes), SSI.Cluster.info(n)[:persistent]]
      end

    IO.write(Format.table(~w(HOST SIZE AVAILABLE BLOBS BLOB-BYTES PERSISTENT), rows))
    IO.puts("replication factor: #{SSI.Blob.replicas()}  #{inspect(SSI.Store.stats())}")
    @quiet
  end

  def dmesg(host \\ nil) do
    n = if host, do: SSI.Proc.resolve_node(host), else: node()

    case :erpc.call(n, SSI.Sys, :dmesg, []) do
      text when is_binary(text) -> IO.write(text)
      error -> IO.puts("dmesg: #{inspect(error)}")
    end

    @quiet
  end

  def services do
    rows =
      for s <- SSI.Service.list() do
        [inspect(s.name), inspect(s.module), s.node && SSI.Cluster.hostname(s.node), s.pinned && SSI.Cluster.hostname(s.pinned)]
      end

    IO.write(Format.table(~w(SERVICE MODULE RUNNING-ON PINNED), rows))
    @quiet
  end

  def migrate(name, host), do: SSI.Service.move(name, host)

  def register_service(name, module, args \\ %{}), do: SSI.Service.register(name, module, args)

  # -- processes --------------------------------------------------------------

  def ps(opts \\ []) do
    list = SSI.Proc.ps(opts) |> Enum.sort_by(&{&1.host, &1.pid})
    rows = for p <- list, do: [p.id, p.name, p.reductions, Format.bytes(p.memory), p.queue, p.status]
    IO.write(Format.table(~w(PID NAME REDUCTIONS MEMORY MSGQ STATE), rows))
    IO.puts("#{length(list)} processes on #{SSI.Cluster.size()} nodes")
    @quiet
  end

  def top(n \\ 15) do
    rows = for p <- SSI.Proc.top(n), do: [p.id, p.name, p.delta, Format.bytes(p.memory), p.queue]
    IO.write(Format.table(~w(PID NAME REDS/S MEMORY MSGQ), rows))

    for s <- SSI.Load.cluster() do
      IO.puts("#{String.pad_trailing(SSI.Cluster.hostname(s.node), 16)} [#{Format.bar(s.util, 30)}] #{Format.percent(s.util)}")
    end

    @quiet
  end

  def kill(pid), do: SSI.Proc.kill(pid)
  def pinfo(pid), do: SSI.Proc.info(pid)

  # -- placement --------------------------------------------------------------

  def run(fun), do: SSI.Sched.run(fun)

  def on(host, fun) do
    case SSI.Sched.run_on(SSI.Proc.resolve_node(host), fun) do
      {:ok, result} -> result
      {:error, reason} -> exit(reason)
    end
  end

  def pmap(enum, fun), do: SSI.Sched.pmap(enum, fun)
  def spawn_anywhere(fun), do: SSI.Sched.spawn(fun)

  # -- files ------------------------------------------------------------------

  def pwd do
    IO.puts(SSI.FS.cwd())
    @quiet
  end

  def cd(path \\ "/"), do: SSI.FS.cd(path)

  def ls(path \\ ".") do
    case SSI.FS.ls(path) do
      {:ok, entries} ->
        for e <- entries do
          name = if e.type == :dir, do: e.name <> "/", else: e.name
          size = if e.type == :dir, do: "", else: Format.bytes(e.size)
          IO.puts(String.pad_leading(size, 8) <> "  " <> name)
        end

        @quiet

      error ->
        error
    end
  end

  def tree(path \\ ".", depth \\ 3) do
    tree(SSI.FS.expand(path), "", depth)
    @quiet
  end

  defp tree(_path, _indent, 0), do: true

  defp tree(path, indent, depth) do
    with {:ok, entries} <- SSI.FS.ls(path) do
      for e <- entries, not (path == "/" and e.name in ["proc", "node"]) do
        IO.puts(indent <> e.name <> if(e.type == :dir, do: "/", else: ""))
        if e.type == :dir, do: tree(Path.join(path, e.name), indent <> "  ", depth - 1)
      end
    end

    true
  end

  def cat(path) do
    case SSI.FS.read(path) do
      {:ok, data} ->
        IO.write(data)
        @quiet

      error ->
        error
    end
  end

  def write(path, data), do: SSI.FS.write(path, data)
  def append(path, data), do: SSI.FS.append(path, data)
  def mkdir(path), do: SSI.FS.mkdir_p(path)
  def rm(path), do: SSI.FS.rm(path)
  def rm_rf(path), do: SSI.FS.rm_rf(path)
  def mv(from, to), do: SSI.FS.rename(from, to)
  def cp(from, to), do: SSI.FS.cp(from, to)

  # -- demos ------------------------------------------------------------------

  @doc """
  Render the Mandelbrot set in ASCII with one row per task, farmed across the
  cluster. The right margin shows which machine computed each row.
  """
  def mandel(width \\ 72, height \\ 30, max \\ 200) do
    view = SSI.Demo.Mandelbrot.default_view()
    hosts = SSI.Cluster.members() |> Enum.with_index() |> Map.new(fn {n, i} -> {n, <<?A + i>>} end)
    rows = :ets.new(:mandel, [:set, :private])

    stats =
      SSI.Sched.each(0..(height - 1), &{&1, SSI.Demo.Mandelbrot.row(view, &1 * 2.0, width, height * 2, max)}, [], fn i, n, {_, iters} ->
        :ets.insert(rows, {i, n, iters})
      end)

    for i <- 0..(height - 1) do
      [{^i, n, iters}] = :ets.lookup(rows, i)
      IO.puts(Enum.map_join(iters, &SSI.Demo.Mandelbrot.glyph(&1, max)) <> " " <> Map.get(hosts, n, "?"))
    end

    :ets.delete(rows)

    for {n, letter} <- Enum.sort_by(hosts, &elem(&1, 1)) do
      IO.puts("#{letter} = #{SSI.Cluster.hostname(n)}: #{Map.get(stats.nodes, n, 0)} rows")
    end

    @quiet
  end

  @doc "Count primes below `n` on one scheduler, then across the whole cluster."
  def bench(n \\ 2_000_000) do
    chunks = SSI.Cluster.summary().schedulers * 4
    step = div(n, chunks) + 1
    ranges = for i <- 0..(chunks - 1), do: {i * step, min((i + 1) * step, n)}
    count = fn {a, b} -> Enum.count(a..(b - 1)//1, &prime?/1) end

    {t1, c1} = :timer.tc(fn -> SSI.Sched.run_on(node(), fn -> count.({0, div(n, 8)}) end) |> elem(1) end)
    {t2, cs} = :timer.tc(fn -> SSI.Sched.pmap(ranges, count) end)
    single = t1 * 8

    IO.puts("one core (extrapolated): #{div(single, 1000)} ms   (#{c1} primes below #{div(n, 8)})")
    IO.puts("cluster (#{SSI.Cluster.summary().schedulers} schedulers):  #{div(t2, 1000)} ms   (#{Enum.sum(cs)} primes below #{n})")
    IO.puts("speed-up: #{Float.round(single / max(t2, 1), 1)}x")
    @quiet
  end

  @doc false
  def prime?(n) when n < 2, do: false
  def prime?(n) when n < 4, do: true
  def prime?(n) when rem(n, 2) == 0, do: false
  def prime?(n), do: prime_check(n, 3)

  defp prime_check(n, d) when d * d > n, do: true
  defp prime_check(n, d) when rem(n, d) == 0, do: false
  defp prime_check(n, d), do: prime_check(n, d + 2)

  @doc "Start (or retarget) the cluster desktop on a RemoteOS-SDL service."
  def desktop(endpoint \\ SSI.Config.get("desktop")), do: SSI.Desktop.enable(endpoint)

  # -- power ------------------------------------------------------------------

  def reboot(target \\ :local), do: SSI.Power.restart(target)
  def poweroff(target \\ :local), do: SSI.Power.poweroff(target)

  # -- monitor ----------------------------------------------------------------

  @doc "A one-time code (10 minutes) that lets a monitor in a browser called `name` control the system."
  def monitor_pair(name) do
    code = SSI.Web.Control.pair(name)
    IO.puts("Pairing code for #{name}: #{code}\nEnter it in the monitor within 10 minutes; it works once.")
    @quiet
  end

  @doc "The monitor keys allowed to change the system."
  def monitor_keys do
    rows =
      for k <- Enum.sort_by(SSI.Web.Control.keys(), & &1.added_at) do
        [k.id, k.name, DateTime.from_unix!(k.added_at, :millisecond) |> DateTime.truncate(:second), k.via]
      end

    IO.write(Format.table(~w(KEY NAME ADDED VIA), rows))
    @quiet
  end

  @doc "Stop trusting a monitor key, by id or name."
  def monitor_revoke(id_or_name) do
    case SSI.Web.Control.revoke(to_string(id_or_name)) do
      [] -> IO.puts("no monitor key #{id_or_name}")
      ids -> IO.puts("revoked #{Enum.join(ids, ", ")}")
    end

    @quiet
  end

  @doc "The web CA's public-key fingerprint, to check a downloaded /ca.pem against before trusting it."
  def monitor_ca do
    IO.puts("""
    Web CA for cluster #{SSI.Cluster.Identity.cluster()} (any member's /ca.pem)
    SHA-256 public key (SPKI), base64: #{SSI.Web.TLS.fingerprint()}
    """)

    @quiet
  end
end
