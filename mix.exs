defmodule Wardrik.MixProject do
  use Mix.Project

  def project do
    [
      app: :wardrik,
      version: "0.1.0-rc.2",
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
        "pages/orgs.md",
        "pages/access.md",
        "pages/operations.md",
        "pages/approvals.md",
        "pages/servers.md",
        "pages/credentials.md",
        "pages/events.md",
        "CHANGELOG.md"
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
      sibling(:wardrik_core, "~> 0.1.0-rc.2"),
      sibling(:wardrik_store, "~> 0.1.0-rc.1"),
      sibling(:wardrik_protocol, "~> 0.1.0-rc.2"),
      sibling(:wardrik_events, "~> 0.1.0-rc.1"),
      sibling(:wardrik_policy, "~> 0.1.0-rc.1"),
      sibling(:wardrik_vault, "~> 0.1.0-rc.2"),
      sibling(:wardrik_oauth, "~> 0.1.0-rc.2"),
      sibling(:wardrik_mcp, "~> 0.1.0-rc.2"),
      sibling(:wardrik_triggers, "~> 0.1.0-rc.2"),
      sibling(:wardrik_workspace, "~> 0.1.0-rc.1"),
      sibling(:wardrik_http, "~> 0.1.0-rc.2"),
      sibling(:wardrik_channel, "~> 0.1.0-rc.2"),
      sibling(:wardrik_slack, "~> 0.1.0-rc.2", only: :test),
      {:durable_server, "~> 0.1.6"},
      {:req, "~> 0.7"},
      {:ekv, "~> 0.4.8"},
      {:jsv, "~> 0.26"},
      {:nimble_options, "~> 1.1"},
      {:ecto_sql, "~> 3.13", optional: true},
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

  # Wardrik's own packages come from Hex, or from their checkouts beside this one with
  # WARDRIK_LOCAL=1.
  defp sibling(name, requirement, opts \\ []) do
    if System.get_env("WARDRIK_LOCAL"),
      do: {name, Keyword.put(opts, :path, "../#{name}")},
      else: {name, requirement, opts}
  end
end
