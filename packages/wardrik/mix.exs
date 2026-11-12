defmodule Wardrik.MixProject do
  use Mix.Project

  def project do
    [
      app: :wardrik,
      version: "0.1.0-rc.10",
      elixir: "~> 1.20",
      description:
        "Agents, governed: rules the model can't rewrite, approvals, budgets, and a record of what they did.",
      package: package(),
      docs: docs(),
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      test_coverage: [ignore_modules: ignored_by_coverage()],
      aliases: aliases(),
      dialyzer: [
        plt_add_apps: [:mix, :ex_unit, :ecto, :ecto_sql, :postgrex, :db_connection, :xmerl],
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

  defp ignored_by_coverage do
    support = [
      Wardrik.Store.Conformance,
      Wardrik.Store.DurableConformance,
      Wardrik.Store.Counter,
      Wardrik.Store.TestRepo,
      Wardrik.Store.TestMigration,
      Wardrik.Store.Test.S3Bucket,
      Wardrik.Store.Ecto.Repo.V1,
      Wardrik.OAuth.GitHub,
      Wardrik.OAuth.TestHook
    ]

    if System.get_env("DATABASE_URL"),
      do: support,
      else:
        support ++
          [
            Wardrik.Store.Ecto,
            Wardrik.Store.Ecto.Migration,
            Wardrik.Store.Ecto.Repo,
            Wardrik.Store.Ecto.Repo.V1
          ]
  end

  defp docs do
    [
      main: "readme",
      extras: [
        "README.md",
        "notebooks/tour-demo.livemd",
        "notebooks/policies-demo.livemd",
        "notebooks/approvals-demo.livemd",
        "notebooks/tools-demo.livemd",
        "notebooks/budgets-demo.livemd",
        "notebooks/durability-demo.livemd",
        "notebooks/triggers-demo.livemd",
        "notebooks/events-demo.livemd",
        "notebooks/access-demo.livemd",
        "pages/running-wardrik.md",
        "pages/talking.md",
        "pages/definitions.md",
        "pages/triggers.md",
        "pages/policies.md",
        "pages/access.md",
        "pages/operations.md",
        "pages/approvals.md",
        "pages/servers.md",
        "pages/credentials.md",
        "pages/events.md",
        "pages/storage.md",
        "pages/files.md",
        "pages/http.md",
        "pages/chat.md",
        "pages/testing.md",
        "CHANGELOG.md"
      ],
      groups_for_modules: [
        Store: [Wardrik.Store, ~r/^Wardrik\.Store\./],
        "Event log": [Wardrik.EventLog, ~r/^Wardrik\.EventLog\./],
        Policy: [Wardrik.Policy, ~r/^Wardrik\.Policy\./],
        Vault: [Wardrik.Vault, ~r/^Wardrik\.Vault\./],
        OAuth: [Wardrik.OAuth, ~r/^Wardrik\.OAuth\./],
        MCP: [Wardrik.MCP, ~r/^Wardrik\.MCP\./],
        Triggers: [Wardrik.Triggers, ~r/^Wardrik\.Triggers\./],
        Workspace: [Wardrik.Workspace, ~r/^Wardrik\.Workspace\./],
        HTTP: [Wardrik.HTTP, ~r/^Wardrik\.HTTP\./],
        Chat: [Wardrik.Chat, ~r/^Wardrik\.Chat\./],
        Testing: [Wardrik.Testing, ~r/^Wardrik\.Testing\./]
      ],
      groups_for_extras: [
        "See it in action": ~r"notebooks/",
        Guides: ~r"pages/"
      ]
    ]
  end

  defp package do
    [
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => "https://github.com/wardrik-dev/wardrik"},
      files: ~w(lib pages notebooks mix.exs README.md CHANGELOG.md LICENSE)
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
      sibling(:wardrik_core, "~> 0.1.0-rc.6"),
      sibling(:wardrik_protocol, "~> 0.1.0-rc.7"),
      {:durable_server, "~> 0.1.7"},
      {:req, "~> 0.7"},
      {:ekv, "~> 0.4.8"},
      {:jsv, "~> 0.26"},
      {:nimble_options, "~> 1.1"},
      {:group, "~> 0.2"},
      {:telemetry, "~> 1.0"},
      {:tz, "~> 0.28"},
      {:crontab, "~> 1.1"},
      {:saxy, "~> 1.6"},
      # 2.2 speaks MCP 2026-07-28 without sending Mcp-Param-* headers (anubis-mcp#332).
      {:anubis_mcp, "~> 2.1.0"},
      {:plug, "~> 1.16"},
      {:bandit, "~> 1.14 and >= 1.14.1"},
      {:websock_adapter, "~> 0.5"},
      {:ecto_sql, "~> 3.13", optional: true},
      {:postgrex, "~> 0.22", optional: true},
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

  # Wardrik's own packages come from this repository, or from Hex with WARDRIK_HEX=1, as when
  # publishing.
  defp sibling(name, requirement, opts \\ []) do
    if System.get_env("WARDRIK_HEX"),
      do: {name, requirement, opts},
      else: {name, Keyword.put(opts, :path, sibling_path(name))}
  end

  defp sibling_path(name), do: __DIR__ |> Path.join("../../*/#{name}") |> Path.wildcard() |> hd()
end
