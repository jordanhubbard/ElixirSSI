defmodule SSI.Cluster.Epmd do
  @moduledoc """
  Replacement for the Erlang Port Mapper Daemon.

  Conventional Erlang hosts run a separate `epmd` program that maps node
  names to distribution ports. ElixirSSI has exactly one BEAM per machine and
  every node listens on the same fixed port, so the mapping is a constant and
  no daemon is needed. Selected with `-epmd_module Elixir.SSI.Cluster.Epmd`
  in the release's `vm.args` (target only; hosted runs keep standard epmd).
  """

  @port 4370
  @version 6

  def dist_port, do: @port

  def start_link, do: :ignore

  def register_node(name, port), do: register_node(name, port, :inet)

  # Creation distinguishes incarnations of a node name; any non-zero 32-bit
  # value that differs across reboots will do.
  def register_node(_name, _port, _family), do: {:ok, :rand.uniform(0xFFFFFFF0) + 3}

  def listen_port_please(_name, _host), do: {:ok, @port}

  def port_please(name, ip), do: port_please(name, ip, :infinity)
  def port_please(_name, _ip, _timeout), do: {:port, @port, @version}

  def address_please(_name, host, family) do
    with {:ok, ip} <- :inet.getaddr(host, family), do: {:ok, ip, @port, @version}
  end

  def names(_host), do: {:error, :address}
end
