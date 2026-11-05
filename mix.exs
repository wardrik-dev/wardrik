defmodule WardrikStore.MixProject do
  use Mix.Project

  def project do
    [
      app: :wardrik_store,
      version: "0.1.0-rc.4",
      elixir: "~> 1.20",
      description: "A durable key-value store that Wardrik packages keep their data in.",
      package: package(),
      docs: [main: "readme", extras: ["README.md", "CHANGELOG.md"]],
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      aliases: aliases(),
      test_coverage: [ignore_modules: ignored_by_coverage()],
      dialyzer: [
        plt_add_apps: [
          :mix,
          :ex_unit,
          :ekv,
          :ecto,
          :ecto_sql,
          :postgrex,
          :db_connection,
          :durable_server
        ],
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
      WardrikStore.Conformance,
      WardrikStore.DurableConformance,
      WardrikStore.Counter,
      WardrikStore.TestRepo,
      WardrikStore.TestMigration,
      WardrikStore.Ecto.Repo.V1
    ]

    if System.get_env("DATABASE_URL"),
      do: support,
      else:
        support ++
          [
            WardrikStore.Ecto,
            WardrikStore.Ecto.Migration,
            WardrikStore.Ecto.Repo,
            WardrikStore.Ecto.Repo.V1
          ]
  end

  defp package do
    [
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => "https://github.com/wardrik-dev/wardrik_store"},
      files: ~w(lib mix.exs README.md CHANGELOG.md LICENSE)
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
      {:ekv, "~> 0.4.8", optional: true},
      {:ecto_sql, "~> 3.13", optional: true},
      {:postgrex, "~> 0.22", optional: true},
      {:durable_server, "~> 0.1.6", optional: true},
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
