defmodule SSI.Proc do
  @moduledoc """
  One process table for the whole cluster.

  BEAM process identifiers are already location-transparent: a pid created on
  any member can be sent to, linked, monitored or killed from any other. This
  module adds the system-administration view on top: `ps/1` lists every
  process on every member, `top/1` ranks them by work done, and processes are
  named in shell output as `HOST:<0.123.0>` — the host plus the pid as its own
  node prints it — which `pid/1` turns back into a real pid.
  """

  @fields [:registered_name, :current_function, :initial_call, :reductions, :memory, :message_queue_len, :status, :dictionary]

  @doc "Processes on every member. Options: `:node`, `:name` (substring filter)."
  def ps(opts \\ []) do
    nodes = if n = opts[:node], do: [resolve_node(n)], else: SSI.Cluster.members()

    nodes
    |> :erpc.multicall(__MODULE__, :local, [], 5_000)
    |> Enum.flat_map(fn
      {:ok, list} -> list
      _ -> []
    end)
    |> filter(opts[:name])
  end

  defp filter(list, nil), do: list
  defp filter(list, text), do: Enum.filter(list, &String.contains?(&1.name, to_string(text)))

  @doc false
  def local do
    host = SSI.Boot.hostname()

    for pid <- Process.list(), info = Process.info(pid, @fields), info != nil do
      %{
        pid: pid,
        id: host <> ":" <> (pid |> :erlang.pid_to_list() |> List.to_string()),
        node: node(),
        host: host,
        name: label(pid, info),
        reductions: info[:reductions],
        memory: info[:memory],
        queue: info[:message_queue_len],
        status: info[:status],
        current: mfa(info[:current_function])
      }
    end
  end

  defp label(_pid, info) do
    cond do
      is_atom(info[:registered_name]) and info[:registered_name] not in [nil, []] ->
        inspect(info[:registered_name])

      ic = info[:dictionary][:"$initial_call"] ->
        mfa(ic)

      true ->
        mfa(info[:initial_call])
    end
  end

  defp mfa({m, f, a}), do: "#{inspect(m)}.#{f}/#{a}"
  defp mfa(_), do: "?"

  @doc """
  The `n` processes that did the most work over `interval` milliseconds,
  cluster-wide. Each entry gains `:delta` (reductions in the interval).
  """
  def top(n \\ 15, interval \\ 1_000) do
    before = Map.new(ps(), &{&1.pid, &1.reductions})
    Process.sleep(interval)

    ps()
    |> Enum.map(&Map.put(&1, :delta, &1.reductions - Map.get(before, &1.pid, 0)))
    |> Enum.sort_by(& &1.delta, :desc)
    |> Enum.take(n)
  end

  @doc "Total processes in the system, from the load gossip (no round trips)."
  def count, do: SSI.Load.cluster() |> Enum.map(& &1.processes) |> Enum.sum()

  @doc "Parse `HOST:<0.1.0>`, `\"<0.1.0>\"` (local), or pass a pid through."
  def pid(pid) when is_pid(pid), do: pid

  def pid(text) when is_binary(text) do
    case String.split(text, ":", parts: 2) do
      [host, local] -> :erpc.call(resolve_node(host), :erlang, :list_to_pid, [String.to_charlist(local)])
      [local] -> :erlang.list_to_pid(String.to_charlist(local))
    end
  end

  def kill(pid, reason \\ :kill), do: Process.exit(pid(pid), reason)

  def info(pid) do
    pid = pid(pid)
    :erpc.call(node(pid), Process, :info, [pid])
  end

  @doc "Accept a node atom, a host name, or a node-name string."
  def resolve_node(n) when is_atom(n), do: n

  def resolve_node(n) when is_binary(n) do
    Enum.find(SSI.Cluster.members(), fn m -> SSI.Cluster.hostname(m) == n or Atom.to_string(m) == n end) ||
      raise ArgumentError, "no member named #{n}"
  end
end
