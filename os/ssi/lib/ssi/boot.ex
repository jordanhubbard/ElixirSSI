defmodule SSI.Boot do
  @moduledoc """
  Early system initialisation, run synchronously before the supervision tree.

  The PID-1 shim has already mounted `/proc`, `/sys`, `/dev` and the tmpfs
  scratch areas. This module finishes the job in Elixir: quiets the kernel
  console, loads drivers for discovered devices, mounts the boot partition
  (re-reading configuration from it) and the persistent data partition, names
  the machine, and writes the handful of `/etc` files that OTP's resolver and
  IEx read.
  """
  require Logger

  @boot_candidates ~w(/dev/mmcblk0p1 /dev/mmcblk1p1 /dev/vdb1 /dev/vdb)
  @data_candidates ~w(/dev/mmcblk0p2 /dev/mmcblk1p2 /dev/nvme0n1p1 /dev/vda)

  def run do
    if SSI.Sys.target?(), do: run_target(), else: run_hosted()
    File.mkdir_p!(data_dir())
    File.mkdir_p!(Path.join(data_dir(), "blobs"))
    SSI.Status.BootRecord.start()
    :ok
  end

  @doc "Directory holding this node's persistent state (store log, blobs, keys)."
  def data_dir do
    case :persistent_term.get({__MODULE__, :data_dir}, nil) do
      nil -> Application.get_env(:ssi, :data_dir) || hosted_data_dir()
      dir -> dir
    end
  end

  @doc "Whether `data_dir/0` survives a reboot."
  def persistent?, do: :persistent_term.get({__MODULE__, :persistent}, not SSI.Sys.target?())

  defp hosted_data_dir do
    Path.join(System.tmp_dir!(), "ssi-" <> (node() |> to_string() |> String.replace(~r/[^\w.-]/, "_")))
  end

  defp run_hosted do
    SSI.Config.load()
    :persistent_term.put({__MODULE__, :persistent}, true)
  end

  defp run_target do
    # Keep kernel chatter (level >= 4) off the console that hosts the shell.
    File.write("/proc/sys/kernel/printk", "4 4 1 7")
    SSI.Config.load()
    {:ok, loaded} = SSI.Devices.coldplug()
    Logger.info("boot: loaded #{length(loaded)} driver modules")
    mount_boot()
    SSI.Config.reload()
    mount_data()
    name_machine()
    write_etc()
    :ok
  end

  defp mount_boot do
    File.mkdir_p!("/boot")

    candidates =
      case SSI.Config.get("boot") do
        "auto" -> @boot_candidates
        "none" -> []
        dev -> [dev]
      end

    case first_device(candidates, 3_000) do
      nil ->
        Logger.info("boot: no boot partition; using kernel command line only")

      dev ->
        case SSI.Sys.mount(dev, "/boot", "vfat", [:rdonly, :nosuid, :nodev, :noexec], "") do
          :ok -> Logger.info("boot: mounted #{dev} on /boot")
          error -> Logger.warning("boot: cannot mount #{dev}: #{inspect(error)}")
        end
    end
  end

  defp mount_data do
    File.mkdir_p!("/data")

    candidates =
      case SSI.Config.get("data") do
        "auto" -> @data_candidates
        "tmpfs" -> []
        dev -> [dev]
      end

    mounted =
      Enum.find_value(candidates, fn dev ->
        File.exists?(dev) and SSI.Sys.mount(dev, "/data", "ext4", [:noatime], "") == :ok && dev
      end)

    if mounted do
      Logger.info("boot: persistent storage #{mounted} on /data")
      :persistent_term.put({__MODULE__, :persistent}, true)
    else
      SSI.Sys.mount("tmpfs", "/data", "tmpfs", [:nosuid, :nodev], "mode=0755")
      Logger.warning("boot: no data partition; /data is volatile tmpfs")
      :persistent_term.put({__MODULE__, :persistent}, false)
    end

    :persistent_term.put({__MODULE__, :data_dir}, "/data/ssi")
  end

  defp name_machine do
    name = SSI.Config.get("hostname") || default_hostname()
    SSI.Sys.sethostname(name)
    :persistent_term.put({__MODULE__, :hostname}, name)
  end

  @doc "This machine's host name."
  def hostname do
    :persistent_term.get({__MODULE__, :hostname}, nil) ||
      (with {:ok, h} <- :inet.gethostname(), do: to_string(h))
  end

  defp default_hostname do
    mac =
      SSI.Net.Link.ethernet()
      |> Enum.map(&SSI.Net.Link.mac/1)
      |> Enum.find(&(&1 != nil))

    case mac do
      <<_, _, _, a, b, c>> -> "ssi-" <> Base.encode16(<<a, b, c>>, case: :lower)
      _ -> "ssi-" <> Base.encode16(:crypto.strong_rand_bytes(3), case: :lower)
    end
  end

  defp write_etc do
    File.mkdir_p!("/etc")
    File.write!("/etc/hosts", "127.0.0.1 localhost #{hostname()}\n")
    File.write!("/etc/nsswitch.conf", "hosts: files dns\n")
    unless File.exists?("/etc/resolv.conf"), do: File.write!("/etc/resolv.conf", "")
    File.mkdir_p!("/root")
    File.write!("/root/.iex.exs", SSI.Shell.dot_iex())
  end

  defp first_device(candidates, wait_ms) do
    deadline = System.monotonic_time(:millisecond) + wait_ms
    wait_for(candidates, deadline)
  end

  defp wait_for([], _), do: nil

  defp wait_for(candidates, deadline) do
    case Enum.find(candidates, &File.exists?/1) do
      nil ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(100)
          wait_for(candidates, deadline)
        end

      dev ->
        dev
    end
  end
end
