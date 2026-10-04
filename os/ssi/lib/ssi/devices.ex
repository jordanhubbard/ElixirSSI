defmodule SSI.Devices do
  @moduledoc """
  Device manager: the job udev and modprobe do on a conventional Linux system.

  The kernel lists every device a driver could claim under its bus in
  `/sys/bus/*/devices`, each carrying a `modalias` string. Coldplug
  walks those strings, matches them against the glob patterns in
  `modules.alias`, resolves dependencies through `modules.dep`, and loads the
  `.ko` files from the initramfs with `finit_module(2)`. A low-frequency rescan
  picks up hot-plugged devices (USB, mostly) without a netlink listener.

  Drivers on the CM5 boot path (PCIe, RP1, Ethernet, eMMC) are built into the
  kernel, so a missing module never prevents the node from joining a cluster.
  """
  use GenServer
  require Logger

  @rescan_ms 10_000

  def start_link(_), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @doc "Synchronously load drivers for all currently visible devices."
  def coldplug do
    case module_db() do
      nil -> {:ok, []}
      db -> {:ok, scan(db, MapSet.new()) |> elem(1)}
    end
  end

  @doc "Modules currently loaded into the kernel."
  def loaded do
    case File.read("/proc/modules") do
      {:ok, text} -> text |> String.split("\n", trim: true) |> Enum.map(&hd(String.split(&1)))
      _ -> []
    end
  end

  @doc "Every device with a modalias, with the module it maps to (if any)."
  def list do
    db = module_db()

    for {path, alias_} <- modaliases() do
      %{device: Path.relative_to(path, "/sys/bus"), modalias: alias_, module: db && match(db, alias_)}
    end
  end

  @impl true
  def init(_) do
    if SSI.Sys.target?() do
      Process.send_after(self(), :rescan, @rescan_ms)
      {:ok, %{db: module_db(), seen: MapSet.new(modaliases() |> Enum.map(&elem(&1, 1)))}}
    else
      :ignore
    end
  end

  @impl true
  def handle_info(:rescan, %{db: nil} = state), do: {:noreply, state}

  def handle_info(:rescan, state) do
    {seen, _} = scan(state.db, state.seen)
    Process.send_after(self(), :rescan, @rescan_ms)
    {:noreply, %{state | seen: seen}}
  end

  # -- module database --------------------------------------------------------

  defp module_dir do
    {:ok, release} = File.read("/proc/sys/kernel/osrelease")
    Path.join("/lib/modules", String.trim(release))
  end

  @doc false
  def module_db(dir \\ nil) do
    dir = dir || if(SSI.Sys.target?(), do: module_dir())

    with dir when is_binary(dir) <- dir,
         {:ok, aliases} <- File.read(Path.join(dir, "modules.alias")),
         {:ok, deps} <- File.read(Path.join(dir, "modules.dep")) do
      %{dir: dir, aliases: parse_aliases(aliases), deps: parse_deps(deps)}
    else
      _ -> nil
    end
  end

  @doc false
  def parse_aliases(text) do
    entries =
      for "alias " <> rest <- String.split(text, "\n"),
          [pattern, mod] <- [String.split(rest)],
          do: {pattern, normalize(mod)}

    {exact, globs} = Enum.split_with(entries, fn {p, _} -> not String.contains?(p, ["*", "?", "["]) end)

    # Most patterns start with a literal bus prefix ("pci:", "usb:", "of:"),
    # so bucket the globs by it; a device is only tested against its bus.
    %{
      exact: Map.new(exact),
      globs:
        globs
        |> Enum.map(fn {p, mod} -> {bus(p), {glob_to_regex(p), mod}} end)
        |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    }
  end

  defp bus(pattern), do: pattern |> String.split(":", parts: 2) |> hd()

  @doc false
  def parse_deps(text) do
    for line <- String.split(text, "\n", trim: true),
        [file, deps] <- [String.split(line, ":", parts: 2)],
        into: %{} do
      {normalize(Path.basename(file, ".ko")), {file, String.split(deps)}}
    end
  end

  @doc false
  def glob_to_regex(glob) do
    body =
      glob
      |> String.graphemes()
      |> Enum.map_join(fn
        "*" -> ".*"
        "?" -> "."
        "[" -> "["
        "]" -> "]"
        c -> Regex.escape(c)
      end)

    Regex.compile!("^" <> body <> "$")
  end

  @doc false
  def match(db, modalias) do
    Map.get(db.aliases.exact, modalias) ||
      db.aliases.globs
      |> Map.get(bus(modalias), [])
      |> Enum.find_value(fn {re, mod} -> Regex.match?(re, modalias) && mod end)
  end

  defp normalize(name), do: String.replace(name, "-", "_")

  # -- scanning ---------------------------------------------------------------

  # Devices a driver can bind are listed flat under their bus
  # (/sys/bus/BUS/devices/*) or class (/sys/class/CLASS/*), and the CPU's
  # feature set (which selects crypto-extension modules) has one modalias of
  # its own. Reading those costs one read per device, with no recursive walk
  # of /sys/devices, whose driver/subsystem symlinks loop back up the tree.
  defp modaliases do
    buses = for bus <- ls("/sys/bus"), dev <- ls(Path.join(["/sys/bus", bus, "devices"])), do: Path.join(["/sys/bus", bus, "devices", dev])
    classes = for class <- ls("/sys/class"), dev <- ls(Path.join("/sys/class", class)), do: Path.join(["/sys/class", class, dev])

    for path <- ["/sys/devices/system/cpu" | buses ++ classes],
        {:ok, a} <- [File.read(Path.join(path, "modalias"))],
        (a = String.trim(a)) != "",
        uniq: true,
        do: {path, a}
  end

  defp ls(dir) do
    case File.ls(dir) do
      {:ok, names} -> names
      _ -> []
    end
  end

  defp scan(db, seen) do
    fresh = modaliases() |> Enum.map(&elem(&1, 1)) |> Enum.reject(&MapSet.member?(seen, &1))
    loaded = MapSet.new(loaded())

    mods =
      fresh
      |> Enum.map(&match(db, &1))
      |> Enum.reject(&(&1 == nil or MapSet.member?(loaded, &1)))
      |> Enum.uniq()

    Enum.each(mods, &load(db, &1))
    {Enum.into(fresh, seen), mods}
  end

  @doc "Load a module and its dependencies by name."
  def load(db, mod) do
    case db.deps[mod] do
      nil ->
        {:error, :unknown_module}

      {file, deps} ->
        deps |> Enum.reverse() |> Enum.each(&load_file(db, &1))
        load_file(db, file)
    end
  end

  defp load_file(db, file) do
    case SSI.Sys.finit_module(Path.join(db.dir, file), "") do
      :ok -> Logger.debug("devices: loaded #{Path.basename(file)}")
      {:error, reason} -> Logger.debug("devices: #{Path.basename(file)}: #{reason}")
    end
  end
end
