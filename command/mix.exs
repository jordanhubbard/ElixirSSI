defmodule ElixirSSI.Command.MixProject do
  use Mix.Project

  @version __DIR__
           |> Path.join("version.json")
           |> File.read!()
           |> JSON.decode!()
           |> Map.fetch!("version")

  def project do
    [
      app: :ssi_command,
      version: @version,
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: [setup: ["deps.get"]]
    ]
  end

  def application do
    [
      mod: {ElixirSSI.Command.Application, []},
      extra_applications: [:logger, :crypto, :inets, :ssl, :ssh]
    ]
  end

  defp deps do
    [
      {:phoenix, "~> 1.8.0"},
      {:phoenix_live_view, "~> 1.1.0"},
      {:phoenix_html, "~> 4.2"},
      {:bandit, "~> 1.7"},
      {:jason, "~> 1.4"},
      {:floki, ">= 0.36.0", only: :test},
      {:lazy_html, "~> 0.1", only: :test}
    ]
  end
end
