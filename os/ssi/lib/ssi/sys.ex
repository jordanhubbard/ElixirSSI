defmodule SSI.Sys do
  @moduledoc """
  Linux system calls the BEAM has no portable API for.

  These are thin wrappers over `os/substrate/ssi_sys_nif.c`. Policy — when to
  mount, which address to assign, which module a device needs — lives in the
  Elixir callers. In hosted mode (tests, development on a workstation) the NIF
  is absent and every call returns `{:error, :hosted}`.
  """

  @on_load :load_nif

  # Linux mount(2) flags used by the system.
  @flags %{rdonly: 0x1, nosuid: 0x2, nodev: 0x4, noexec: 0x8, noatime: 0x400, relatime: 0x200000}

  @doc false
  def load_nif do
    path = :filename.join(:code.priv_dir(:ssi), ~c"ssi_sys_nif")

    case :erlang.load_nif(path, 0) do
      :ok -> :ok
      # Hosted builds ship no NIF; target code paths are never taken there.
      {:error, _} -> :ok
    end
  end

  @doc "True when this BEAM is the operating system (PID 1 on ElixirSSI)."
  def target?, do: Application.get_env(:ssi, :mode) == :target

  @doc "mount(2). `flags` is a list such as `[:rdonly, :noatime]`."
  def mount(source, target, fstype, flags \\ [], data \\ "") do
    mask = Enum.reduce(flags, 0, fn f, acc -> Bitwise.bor(acc, Map.fetch!(@flags, f)) end)
    raw_mount(source, target, fstype, mask, data)
  end

  @doc false
  def raw_mount(_source, _target, _fstype, _flags, _data), do: hosted()
  def umount(_target), do: hosted()
  @doc "Restart, power off, or halt the machine after syncing filesystems."
  def reboot(_how), do: hosted()
  def sync, do: hosted()
  def sethostname(_name), do: hosted()
  def if_up(_name, _up), do: hosted()
  def if_set_ipv4(_name, _address, _netmask), do: hosted()
  def route_add(_name, _destination, _netmask, _gateway), do: hosted()
  def finit_module(_path, _params), do: hosted()
  def statvfs(_path), do: hosted()
  @doc "The kernel log ring buffer."
  def dmesg, do: hosted()
  @doc "Open a terminal device in cooked mode; returns `{:ok, fd}` for an fd port."
  def open_tty(_path), do: hosted()

  # Hosted stubs. The value is read at runtime so the compiler does not
  # specialise callers on the stub's return type: on the target the NIF
  # replaces every one of these functions.
  defp hosted, do: Application.get_env(:ssi, :hosted_result, {:error, :hosted})

  @doc "Bring an interface up (`true`) or down (`false`)."
  def link(name, up?), do: if_up(name, if(up?, do: 1, else: 0))

  @doc "Assign an IPv4 address with a prefix length, e.g. `{10,0,2,15}`, 24."
  def set_ipv4(name, {a, b, c, d}, prefix) do
    if_set_ipv4(name, <<a, b, c, d>>, SSI.Net.Addr.netmask_bin(prefix))
  end

  @doc "Install a default route through `gateway` on interface `name`."
  def default_route(name, {a, b, c, d}) do
    route_add(name, <<0, 0, 0, 0>>, <<0, 0, 0, 0>>, <<a, b, c, d>>)
  end
end
