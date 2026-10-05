defmodule SSI.Config do
  @moduledoc """
  System configuration, resolved once at boot.

  Precedence, lowest first:

    1. built-in defaults (below);
    2. `ssi.conf` on the boot partition — `key = value` lines, `#` comments;
    3. `ssi.KEY=VALUE` words on the kernel command line;
    4. the `:ssi, :config` application environment (hosted mode and tests).

  Keys are dotted strings such as `"net.eth0"`; values stay strings except for
  the few typed accessors below. Every node in a cluster should share
  `cluster` and `secret`; everything else may differ per node.
  """

  @key {__MODULE__, :config}

  @defaults %{
    "cluster" => "ssi",
    "secret" => "elixirssi-insecure-default-secret",
    "hostname" => nil,
    "cluster_if" => nil,
    "peers" => "",
    "replicas" => "2",
    "services.partition" => "auto",
    "desktop" => nil,
    "desktop.size" => "1280x800",
    "ssh.port" => "22",
    "ssh.password" => nil,
    "boot" => "auto",
    "data" => "auto",
    "discovery.port" => "45892",
    "discovery.group" => "239.83.83.73",
    "log" => "info"
  }

  @doc "Load and freeze configuration. `sources` overrides file locations for tests."
  def load(sources \\ []) do
    file = Keyword.get(sources, :file, "/boot/ssi.conf")
    cmdline = Keyword.get(sources, :cmdline, "/proc/cmdline")

    config =
      @defaults
      |> Map.merge(read_conf(file))
      |> Map.merge(read_cmdline(cmdline))
      |> Map.merge(Map.new(Application.get_env(:ssi, :config, %{}), fn {k, v} -> {to_string(k), v} end))

    :persistent_term.put(@key, config)
    config
  end

  @doc "Reload after the boot partition is mounted (it is not readable earlier)."
  def reload, do: load()

  def all, do: :persistent_term.get(@key, @defaults)

  def get(key, default \\ nil), do: Map.get(all(), to_string(key)) || default

  def integer(key, default) do
    case get(key) do
      nil -> default
      value when is_integer(value) -> value
      value -> String.to_integer(String.trim(value))
    end
  end

  @doc "Unicast seed peers (IPv4 strings) for networks without multicast."
  def peers do
    (get("peers") || "") |> String.split([",", " "], trim: true)
  end

  @doc "Per-interface network policy, e.g. `\"dhcp,linklocal\"`."
  def net_policy(ifname), do: get("net." <> ifname, "dhcp,linklocal")

  @doc "True when the cluster still uses the published default secret."
  def insecure_secret?, do: get("secret") == @defaults["secret"]

  @doc false
  def parse_conf(text) do
    text
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
    |> Enum.flat_map(fn line ->
      case String.split(line, "=", parts: 2) do
        [k, v] -> [{String.trim(k), v |> String.trim() |> unquote_value()}]
        _ -> []
      end
    end)
    |> Map.new()
  end

  @doc false
  def parse_cmdline(text) do
    text
    |> String.split()
    |> Enum.flat_map(fn
      "ssi." <> rest ->
        case String.split(rest, "=", parts: 2) do
          [k, v] -> [{k, v}]
          [k] -> [{k, "true"}]
        end

      _ ->
        []
    end)
    |> Map.new()
  end

  defp unquote_value(<<?", rest::binary>>), do: String.trim_trailing(rest, "\"")
  defp unquote_value(v), do: v

  defp read_conf(path) do
    case File.read(path) do
      {:ok, text} -> parse_conf(text)
      _ -> %{}
    end
  end

  defp read_cmdline(path) do
    if SSI.Sys.target?() do
      case File.read(path) do
        {:ok, text} -> parse_cmdline(text)
        _ -> %{}
      end
    else
      %{}
    end
  end
end
