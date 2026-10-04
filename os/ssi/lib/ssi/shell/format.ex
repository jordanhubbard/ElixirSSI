defmodule SSI.Shell.Format do
  @moduledoc "Plain-text tables and units for shell output."
  import Bitwise, only: [<<<: 2]

  def bytes(nil), do: "-"
  def bytes(n) when n >= 1 <<< 30, do: "#{Float.round(n / (1 <<< 30), 1)}G"
  def bytes(n) when n >= 1 <<< 20, do: "#{Float.round(n / (1 <<< 20), 1)}M"
  def bytes(n) when n >= 1 <<< 10, do: "#{Float.round(n / (1 <<< 10), 1)}K"
  def bytes(n), do: "#{n}B"

  def percent(nil), do: "-"
  def percent(f), do: "#{round(f * 100)}%"

  def duration(seconds) do
    {d, rest} = {div(seconds, 86_400), rem(seconds, 86_400)}
    {h, rest} = {div(rest, 3600), rem(rest, 3600)}
    m = div(rest, 60)
    if d > 0, do: "#{d}d #{h}h #{m}m", else: "#{h}h #{m}m #{rem(rest, 60)}s"
  end

  @doc "A horizontal bar of `width` cells for a fraction 0..1."
  def bar(fraction, width \\ 20) do
    filled = round(min(max(fraction || 0.0, 0.0), 1.0) * width)
    String.duplicate("#", filled) <> String.duplicate(".", width - filled)
  end

  @doc "Render rows (lists of cells) under headers as aligned columns."
  def table(headers, rows) do
    rows = Enum.map(rows, fn row -> Enum.map(row, &cell/1) end)
    all = [headers | rows]

    widths =
      all
      |> Enum.zip_with(& &1)
      |> Enum.map(fn col -> col |> Enum.map(&String.length/1) |> Enum.max() end)

    line = fn row ->
      row
      |> Enum.zip(widths)
      |> Enum.map_join("  ", fn {c, w} -> String.pad_trailing(c, w) end)
      |> String.trim_trailing()
    end

    Enum.map_join(all, "\n", line) <> "\n"
  end

  defp cell(c) when is_binary(c), do: c
  defp cell(nil), do: "-"
  defp cell(c) when is_atom(c), do: Atom.to_string(c)
  defp cell(c) when is_integer(c), do: Integer.to_string(c)
  defp cell(c) when is_float(c), do: :erlang.float_to_binary(c, decimals: 2)
  defp cell(c), do: inspect(c)

end
