defmodule SSI.Net.Link do
  @moduledoc "Network interfaces as the kernel reports them in /sys/class/net."

  @sys "/sys/class/net"

  def all do
    case File.ls(@sys) do
      {:ok, names} -> Enum.sort(names)
      _ -> []
    end
  end

  @doc "Ethernet-type interfaces (ARPHRD_ETHER), excluding loopback and virtual bridges."
  def ethernet do
    Enum.filter(all(), fn name ->
      read(name, "type") == "1" and name != "lo" and File.exists?(Path.join([@sys, name, "device"]))
    end)
  end

  def mac(name) do
    case read(name, "address") do
      nil -> nil
      text -> text |> String.split(":") |> Enum.map(&String.to_integer(&1, 16)) |> :erlang.list_to_binary()
    end
  end

  def carrier?(name), do: read(name, "carrier") == "1"
  def mtu(name), do: read(name, "mtu")

  def speed(name) do
    case read(name, "speed") do
      nil -> nil
      text -> String.to_integer(text)
    end
  rescue
    _ -> nil
  end

  def stats(name) do
    for key <- ~w(rx_bytes tx_bytes rx_packets tx_packets), into: %{} do
      {key, (read(name, "statistics/" <> key) || "0") |> String.to_integer()}
    end
  end

  @doc "Wait up to `ms` for carrier on `name`."
  def await_carrier(name, ms) do
    cond do
      carrier?(name) -> true
      ms <= 0 -> false
      true -> Process.sleep(100) && await_carrier(name, ms - 100)
    end
  end

  defp read(name, attr) do
    case File.read(Path.join([@sys, name, attr])) do
      {:ok, v} -> String.trim(v)
      _ -> nil
    end
  end
end
