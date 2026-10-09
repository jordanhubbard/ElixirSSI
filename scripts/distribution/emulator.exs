defmodule ElixirSSI.Emulator.Board do
  use GenServer
  def child_spec(index), do: %{id: index, start: {__MODULE__, :start_link, [index]}, restart: :transient, shutdown: 5000}
  def start_link(index), do: GenServer.start_link(__MODULE__, index)

  @impl true
  def init(index) do
    Process.flag(:trap_exit, true)
    directory = System.get_env("SSI_CM5_STATE_DIR", "/os/build/cm5emu")
    image = "/os/build/cm5/elixirssi-cm5.img"
    emulator = "/os/build/emulator/current"
    File.mkdir_p!(directory)
    hash = File.stream!(image, 4 * 1024 * 1024) |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
      |> :crypto.hash_final() |> Base.encode16(case: :lower) |> binary_part(0, 16)
    card = Path.join(directory, "node#{index}-#{hash}.img")
    unless File.exists?(card) do
      previous = System.get_env("SSI_PREVIOUS_IMAGE", "") |> String.slice(0, 16)
      old = Path.join(directory, "node#{index}-#{previous}.img")
      if previous != "" and File.regular?(old) do
        {_, 0} = System.cmd("cp", ["--sparse=always", old, card <> ".partial"])
        upgrade_boot!(image, card <> ".partial")
      else
        {_, 0} = System.cmd("cp", ["--sparse=always", image, card <> ".partial"])
      end
      File.rename!(card <> ".partial", card)
    end
    prefix = Path.join(directory, "node#{index}")
    for extension <- [".sock", ".mon"], do: File.rm(prefix <> extension)
    mac = index |> Integer.to_string(16) |> String.pad_leading(2, "0")
    append = "ssi.cluster_if=eth0 " <> System.get_env("SSI_CM5_APPEND", "")
    args = [emulator <> "/scripts/rpi5-boot", "--board", "cm5", "--qemu", emulator <> "/build/qemu-system-aarch64",
      "--graphics", "--append", append, card, "--", "-smp", "4", "-m", System.get_env("SSI_CM5_MEM", "4096"),
      "-netdev", "dgram,id=swa,remote.type=inet,remote.host=230.83.83.5,remote.port=18355",
      "-netdev", "hubport,id=pa,hubid=0,netdev=swa", "-netdev", "hubport,id=switch,hubid=0",
      "-global", "rp1.netdev=switch", "-global", "rp1.mac=52:54:00:c5:00:#{mac}",
      "-netdev", "user,id=mgmt,hostfwd=tcp:0.0.0.0:#{8180 + index}-:80,hostfwd=tcp:0.0.0.0:#{8480 + index}-:443,hostfwd=tcp:0.0.0.0:#{2320 + index}-:22",
      "-device", "usb-net,netdev=mgmt,mac=52:54:00:c5:01:#{mac}", "-device", "usb-kbd", "-display", "none",
      "-monitor", "unix:#{prefix}.mon,server=on,wait=off",
      "-chardev", "socket,id=s,path=#{prefix}.sock,server=on,wait=off,logfile=#{prefix}.log",
      "-serial", "null", "-serial", "null", "-serial", "chardev:s"]
    port = Port.open({:spawn_executable, System.find_executable("python3")}, [:binary, :exit_status, :stderr_to_stdout, args: args])
    {:ok, log} = File.open(prefix <> ".boot.log", [:append])
    IO.puts("Elixir supervisor started CM5 #{index}; console: #{prefix}.log")
    {:ok, %{port: port, log: log, index: index}}
  end

  # Replace only an identically laid-out boot partition. Existing /data is copied
  # from the previous card, and that original card is retained for rollback.
  defp upgrade_boot!(image, card) do
    {:ok, source} = :file.open(String.to_charlist(image), [:read, :binary, :raw])
    {:ok, target} = :file.open(String.to_charlist(card), [:read, :write, :binary, :raw])
    try do
      {:ok, header} = :file.pread(source, 0, 512)
      {:ok, old_header} = :file.pread(target, 0, 512)
      unless binary_part(header, 446, 66) == binary_part(old_header, 446, 66), do: raise("Image partition layout changed; refusing automatic card migration")
      <<_::binary-size(454), start::little-32, size::little-32, _::binary>> = header
      offset = start * 512
      length = size * 512
      for position <- Stream.iterate(0, &(&1 + 4_194_304)) |> Enum.take_while(&(&1 < length)) do
        {:ok, bytes} = :file.pread(source, offset + position, min(4_194_304, length - position))
        :ok = :file.pwrite(target, offset + position, bytes)
      end
      :ok = :file.sync(target)
    after
      :file.close(source)
      :file.close(target)
    end
  end

  @impl true
  def handle_info({port, {:data, bytes}}, %{port: port} = state) do
    IO.binwrite(state.log, bytes)
    {:noreply, state}
  end
  def handle_info({port, {:exit_status, code}}, %{port: port} = state),
    do: {:stop, if(code == 0, do: :normal, else: {:emulator_exit, code}), state}
  def handle_info({:EXIT, port, _}, %{port: port} = state), do: {:noreply, state}
  # System.cmd/3 used while preparing a card can leave a normal EXIT queued
  # because this process traps exits. It is not the running emulator's port.
  def handle_info({:EXIT, port, :normal}, state) when is_port(port), do: {:noreply, state}

  @impl true
  def terminate(_, state) do
    if Port.info(state.port), do: Port.close(state.port)
    File.close(state.log)
  end
end

count = System.get_env("SSI_NODES", "3") |> String.to_integer()
unless count in 1..64, do: raise("SSI_NODES must be between 1 and 64")
children = Enum.map(1..count, &{ElixirSSI.Emulator.Board, &1})
{:ok, _} = Supervisor.start_link(children, strategy: :one_for_one, max_restarts: 0, name: ElixirSSI.Emulator.Supervisor)
Process.sleep(:infinity)
