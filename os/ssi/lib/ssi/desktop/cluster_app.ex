defmodule SSI.Desktop.ClusterApp do
  @moduledoc "Live view of every member: identity, hardware, scheduler utilisation history."
  @behaviour SSI.Desktop.App
  alias SSI.Remote
  alias SSI.Desktop.App
  alias SSI.Shell.Format

  @card_w 272
  @card_h 104

  @impl true
  def short, do: "cluster"
  @impl true
  def title, do: "Cluster"
  @impl true
  def size, do: {566, 380}
  @impl true
  def init(_ctx), do: %{seen: 0}
  @impl true
  def message(_, state, _), do: state

  @impl true
  def tick(state, _ctx) do
    latest = SSI.Load.cluster() |> Enum.map(& &1.at) |> Enum.max(fn -> 0 end)
    if latest != state.seen, do: {:dirty, %{state | seen: latest}}, else: state
  end

  @impl true
  def render(_state, ctx, {x, y, w, _h}) do
    fb = ctx.fb
    s = SSI.Cluster.summary()
    loads = Map.new(SSI.Load.cluster(), &{&1.node, &1})
    total_util = loads |> Map.values() |> Enum.map(& &1.util) |> then(&(Enum.sum(&1) / max(length(&1), 1)))
    services = SSI.Service.list() |> Enum.group_by(& &1.node, & &1.name)
    infos = SSI.Cluster.infos()

    header = [
      Remote.text(fb, x + 8, y + 8, "#{s.nodes} machines   #{s.cores} cores   #{s.schedulers} schedulers   #{Format.bytes(s.memory)} RAM", 0xE8EAF0),
      Remote.text(fb, x + 8, y + 20, "aggregate utilisation #{Format.percent(total_util)}", 0x8A90A2),
      Remote.fill(fb, x + 200, y + 20, round((w - 216) * total_util), 7, 0x4C6FBF),
      Remote.rect(fb, x + 200, y + 19, w - 214, 9, 0x5A6378)
    ]

    cards =
      infos
      |> Enum.take(6)
      |> Enum.with_index()
      |> Enum.map(fn {info, i} ->
        cx = x + 8 + rem(i, 2) * (@card_w + 6)
        cy = y + 36 + div(i, 2) * (@card_h + 6)
        card(fb, info, loads[info.node], services[info.node] || [], {cx, cy})
      end)

    more =
      if length(infos) > 6,
        do: [Remote.text(fb, x + 8, y + 36 + 3 * (@card_h + 6), "+ #{length(infos) - 6} more machines", 0x8A90A2)],
        else: []

    [header, cards, more]
  end

  defp card(fb, info, load, services, {x, y}) do
    color = App.node_color(info.node)
    load = load || %{util: 0.0, history: [], processes: 0, mem_total: 1, mem_available: 1, temperature: nil}
    used = (load.mem_total - load.mem_available) / max(load.mem_total, 1)
    here = info.node == node()

    [
      Remote.fill(fb, x, y, @card_w, @card_h, 0x1A1E29),
      Remote.fill(fb, x, y, 4, @card_h, color),
      Remote.text(fb, x + 10, y + 6, info.hostname, color),
      Remote.text(fb, x + 10 + 8 * (String.length(info.hostname) + 1), y + 6, if(here, do: "[desktop]", else: ""), 0x9CC3FF),
      Remote.text(fb, x + 10, y + 18, App.truncate("#{info[:ip]}  #{info[:model]}", 32), 0x8A90A2),
      Remote.text(fb, x + 10, y + 32, "#{info.cores} cores  #{load.processes} procs#{if load.temperature, do: "  #{load.temperature}C", else: ""}", 0xE8EAF0),
      Remote.text(fb, x + 10, y + 46, "cpu #{Format.percent(load.util)}", 0xE8EAF0),
      Remote.fill(fb, x + 74, y + 46, round(110 * load.util), 7, color),
      Remote.rect(fb, x + 74, y + 45, 112, 9, 0x5A6378),
      Remote.text(fb, x + 10, y + 58, "mem #{Format.percent(used)}", 0xE8EAF0),
      Remote.fill(fb, x + 74, y + 58, round(110 * used), 7, 0x8A90A2),
      Remote.rect(fb, x + 74, y + 57, 112, 9, 0x5A6378),
      Remote.text(fb, x + 10, y + 72, App.truncate("svc: " <> Enum.map_join(services, " ", &inspect/1), 32), 0x98C379),
      sparkline(fb, load.history, {x + 194, y + 30, 70, 36}, color)
    ]
  end

  defp sparkline(fb, history, {x, y, w, h}, color) do
    points =
      history
      |> Enum.take(w)
      |> Enum.reverse()
      |> Enum.with_index()
      |> Enum.map(fn {u, i} -> {x + i, y + h - 1 - round(u * (h - 1))} end)

    lines =
      points
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.map(fn [{x0, y0}, {x1, y1}] -> Remote.line(fb, x0, y0, x1, y1, color) end)

    [Remote.rect(fb, x - 1, y - 1, w + 2, h + 2, 0x2C3242), lines]
  end
end
