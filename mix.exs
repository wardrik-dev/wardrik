defmodule Wardrik.MixProject do
  use Mix.Project

  def project do
    [
      app: :wardrik,
      version: "0.1.0",
      elixir: "~> 1.20",
      description:
        "Agents, governed: rules the model can't rewrite, approvals, budgets, and a record of what they did.",
      package: package(),
      docs: docs(),
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      aliases: aliases(),
      dialyzer: [
        plt_add_apps: [:mix, :ex_unit],
        plt_core_path: "priv/plts",
        plt_local_path: "priv/plts"
      ],
      deps: deps()
    ]
  end

  def cli, do: [preferred_envs: [precommit: :test]]

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp docs do
    [
      main: "readme",
      extras: [
        "README.md",
        "pages/running-wardrik.md",
        "pages/talking.md",
        "pages/definitions.md",
        "pages/triggers.md",
        "pages/policies.md",
        "pages/orgs.md",
        "pages/access.md",
        "pages/operations.md",
        "pages/approvals.md",
        "pages/servers.md",
        "pages/credentials.md",
        "pages/events.md",
        "CHANGELOG.md"
      ]
    ]
  end

  defp package do
    [
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => "https://github.com/wardrik-dev/wardrik"},
      files: ~w(lib pages mix.exs README.md CHANGELOG.md LICENSE)
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

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:wardrik_core, path: "../wardrik_core"},
      {:wardrik_store, path: "../wardrik_store"},
      {:wardrik_protocol, path: "../wardrik_protocol"},
      {:wardrik_events, path: "../wardrik_events"},
      {:wardrik_policy, path: "../wardrik_policy"},
      {:wardrik_vault, path: "../wardrik_vault"},
      {:wardrik_oauth, path: "../wardrik_oauth"},
      {:wardrik_mcp, path: "../wardrik_mcp"},
      {:wardrik_triggers, path: "../wardrik_triggers"},
      {:wardrik_workspace, path: "../wardrik_workspace"},
      {:durable_server, "~> 0.1.6"},
      {:req, "~> 0.7"},
      {:ekv, "~> 0.4.8"},
      {:jsv, "~> 0.26"},
      {:ecto_sql, "~> 3.13", only: :test},
      {:postgrex, "~> 0.22", only: :test},
      {:mimic, "~> 2.4", only: :test},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_slop, "~> 0.4", only: [:dev, :test], runtime: false},
      {:ex_dna, "~> 1.5", only: [:dev, :test], runtime: false},
      {:ex_crap, "~> 0.1.0", only: [:dev, :test], runtime: false},
      {:reach, "~> 2.8", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end
end
