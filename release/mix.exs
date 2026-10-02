defmodule Wardrikd.MixProject do
  use Mix.Project

  def project do
    [
      app: :wardrikd,
      version: "0.1.0-rc.1",
      elixir: "~> 1.20",
      releases: releases(),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      # Nothing here but configuration and the release around it.
      precommit: [skip: ["ex_dna", "reach.check", "test.coverage", "crap", "dialyzer"]]
    ]
  end

  def application, do: [extra_applications: [:logger], mod: {Wardrikd.Application, []}]

  defp deps do
    [
      {:wardrik_sdk, path: "../packages/wardrik_sdk"},
      {:wardrik_precommit, path: "../tools/precommit", only: [:dev, :test], runtime: false}
    ]
  end

  # One release carrying its own ERTS. `bin/wardrikd` is the node's own script
  # and `bin/wardrik`, from rel/overlays, the command a person runs.
  # `rel/env.sh.eex` gives each install a cookie of its own and keeps
  # distribution on loopback.
  defp releases do
    [
      wardrikd: [
        include_executables_for: [:unix],
        applications: [wardrik: :permanent],
        steps: [:assemble, :tar]
      ]
    ]
  end
end
