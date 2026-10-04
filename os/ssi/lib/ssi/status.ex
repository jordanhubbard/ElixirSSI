defmodule SSI.Status do
  @moduledoc """
  The cluster's status as one JSON-ready map: what the monitor shows.

  A snapshot describes the system twice — as the one machine it presents
  (`system`, `services`) and as the members that implement it (`members`) —
  together with the observer that produced it and its recent journal. It is
  built from this member's memory only: membership, the hardware
  descriptions cached by `SSI.Cluster`, the load samples every member
  gossips, and the replicated service table. Any member therefore gives the
  same answer without calling the others, and a member cut off from the rest
  answers with its own view, which is how the monitor sees a partition.
  """

  @schema "elixirssi-status/1"

  @doc "The status, as seen from this member. `journal: false` leaves the journal out."
  def snapshot(opts \\ []) do
    infos = Map.new(SSI.Cluster.cached_infos(), &{&1.node, &1})
    loads = Map.new(SSI.Load.cluster(), &{&1.node, &1})
    services = SSI.Service.list()
    hosted = Enum.group_by(services, & &1.node, &label(&1.name))
    members = SSI.Cluster.members()
    samples = Map.values(loads)

    %{
      schema: @schema,
      at: System.os_time(:millisecond),
      observer: %{node: node(), hostname: SSI.Boot.hostname(), boot_id: SSI.Status.BootRecord.boot_id()},
      system: %{
        cluster: SSI.Cluster.Identity.cluster(),
        members: length(members),
        cores: sum(infos, :cores),
        schedulers: sum(infos, :schedulers),
        memory: sum(infos, :memory),
        util: mean(Enum.map(samples, & &1.util)),
        processes: samples |> Enum.map(& &1.processes) |> Enum.sum(),
        insecure_secret: SSI.Config.insecure_secret?()
      },
      members: Enum.map(members, &member(&1, infos[&1], loads[&1], hosted[&1] || [])),
      services: Enum.map(services, &service(&1, infos)),
      # Which monitor keys may change the system (ids only), so a monitor
      # knows whether it is paired and sees a revocation at once.
      control: %{keys: SSI.Web.Control.key_ids()}
    }
    |> then(&if Keyword.get(opts, :journal, true), do: Map.put(&1, :journal, SSI.Status.Journal.recent()), else: &1)
  end

  @doc "The snapshot as JSON text."
  def json(opts \\ []), do: JSON.encode!(snapshot(opts))

  @doc "A display name for a service name (any term)."
  def label(name) when is_atom(name), do: Atom.to_string(name)
  def label(name) when is_binary(name), do: name
  def label(name), do: inspect(name)

  defp member(node, info, load, services) do
    info = info || %{}

    %{
      node: node,
      # Unknown until the member's description is cached here, just after
      # it joins; its node name identifies it meanwhile.
      hostname: Map.get(info, :hostname),
      model: info[:model],
      arch: info[:arch],
      kernel: info[:kernel],
      otp: info[:otp],
      elixir: info[:elixir],
      cores: info[:cores],
      schedulers: info[:schedulers],
      memory: info[:memory],
      persistent: info[:persistent],
      booted_at: info[:booted_at] && info[:booted_at] * 1000,
      boot_id: info[:boot_id],
      previous_boot: info[:previous_boot],
      addresses: info[:addresses] || [],
      web_port: info[:web_port],
      web_tls_port: info[:web_tls_port],
      services: services,
      load: load && Map.take(load, [:at, :util, :history, :run_queue, :processes, :mem_total, :mem_available, :temperature])
    }
  end

  defp service(s, infos) do
    %{
      name: label(s.name),
      module: inspect(s.module),
      node: s.node,
      hostname: s.node && ((infos[s.node] || %{})[:hostname] || host(s.node)),
      owner: s.owner,
      pinned: s.pinned,
      running: s.pid != nil
    }
  end

  defp host(node), do: node |> to_string() |> String.split("@") |> List.last()

  defp sum(infos, key), do: infos |> Map.values() |> Enum.map(&(Map.get(&1, key) || 0)) |> Enum.sum()

  defp mean([]), do: 0.0
  defp mean(xs), do: Float.round(Enum.sum(xs) / length(xs), 3)
end
