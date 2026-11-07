defmodule WardrikDaemon.MixProject do
  use Mix.Project

  def project do
    [
      app: :wardrik_daemon,
      version: "0.1.0-rc.9",
      elixir: "~> 1.20",
      description:
        "Wardrik as a daemon: agents from files, config.yaml, an HTTP API, and the wardrik command.",
      package: package(),
      docs: [main: "readme", extras: ["README.md", "CHANGELOG.md"]],
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      aliases: aliases(),
      releases: releases(),
      dialyzer: [
        plt_add_apps: [:mix, :ex_unit],
        plt_core_path: "priv/plts",
        plt_local_path: "priv/plts"
      ],
      deps: deps()
    ]
  end

  def cli, do: [preferred_envs: [precommit: :test]]

  def application do
    [
      mod: {WardrikDaemon.Application, []},
      extra_applications: [:logger, :crypto]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp package do
    [
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => "https://github.com/wardrik-dev/wardrik_daemon"},
      files:
        ~w(lib priv/front_door.md priv/openapi.json rel mix.exs README.md CHANGELOG.md LICENSE)
    ]
  end

  defp releases do
    [
      wardrikd: [
        include_executables_for: [:unix],
        steps: [:assemble, :tar]
      ]
    ]
  end

  defp aliases do
    [
      precommit: [
        "deps.unlock --check-unused",
        "format --check-formatted",
        "credo --strict",
        "ex_dna --max-clones 0",
        "reach.check --arch --smells --strict",
        "test --warnings-as-errors --cover --export-coverage default",
        "test.coverage",
        "crap",
        "dialyzer --force-check"
      ]
    ]
  end

  defp deps do
    [
      sibling(:wardrik, "~> 0.1.0-rc.8"),
      sibling(:wardrik_slack, "~> 0.1.0-rc.4"),
      sibling(:wardrik_lua, "~> 0.1.0-rc.2"),
      sibling(:wardrik_brave, "~> 0.1.0-rc.2"),
      sibling(:wardrik_gateway, "~> 0.1.0-rc.1"),
      sibling(:wardrik_research, "~> 0.1.0-rc.2"),
      sibling(:wardrik_acp, "~> 0.1.0-rc.1"),
      sibling(:wardrik_store, "~> 0.1.0-rc.5"),
      {:req, "~> 0.5"},
      {:ecto_sql, "~> 3.13"},
      {:postgrex, "~> 0.22"},
      {:yaml_elixir, "~> 2.12"},
      {:libcluster, "~> 3.6"},
      {:owl, "~> 0.13"},
      {:telemetry, "~> 1.0"},
      {:mimic, "~> 2.5", only: :test},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_slop, "~> 0.4", only: [:dev, :test], runtime: false},
      {:ex_dna, "~> 1.5", only: [:dev, :test], runtime: false},
      {:ex_crap, "~> 0.1.0", only: [:dev, :test], runtime: false},
      {:reach, "~> 2.8", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  # Wardrik's own packages come from Hex, or from their checkouts beside this one with
  # WARDRIK_LOCAL=1.
  defp sibling(name, requirement, opts \\ []) do
    if System.get_env("WARDRIK_LOCAL"),
      do: {name, Keyword.put(opts, :path, "../#{name}")},
      else: {name, requirement, opts}
  end
end
