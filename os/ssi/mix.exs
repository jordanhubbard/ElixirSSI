defmodule SSI.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      app: :ssi,
      version: @version,
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      deps: [],
      elixirc_paths: if(Mix.env() == :test, do: ["lib", "test/support"], else: ["lib"]),
      releases: releases(),
      test_coverage: [summary: [threshold: 0]]
    ]
  end

  def application do
    [
      mod: {SSI.Application, []},
      extra_applications: [:logger, :crypto, :public_key, :ssl, :ssh, :runtime_tools, :iex]
    ]
  end

  # The release is the operating system image's userland: ERTS, the OTP
  # libraries the system uses, Elixir, and this application. The PID-1 shim
  # (os/substrate/ssi_init.c) boots it directly; the generated bin/ scripts are
  # never used on the target because there is no /bin/sh.
  defp releases do
    [
      ssi: [
        include_erts: true,
        include_executables_for: [],
        strip_beams: [keep: ["Docs"]],
        vm_args: "rel/vm.args.eex"
      ]
    ]
  end
end
