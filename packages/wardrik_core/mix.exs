defmodule WardrikCore.MixProject do
  use Mix.Project

  @version "0.1.0-rc.1"
  @source_url "https://github.com/wardrik-dev/wardrik"

  def project do
    [
      app: :wardrik_core,
      version: @version,
      elixir: "~> 1.20",
      description:
        "The agent runtime inside Wardrik: agents, the fleet, turns, tools and hooks, the store they are kept in, and the schemas of what they say.",
      source_url: @source_url,
      package: package(),
      docs: [main: "readme", extras: ["README.md", "guides/store.md", "guides/protocol.md"]],
      elixirc_paths: elixirc_paths(Mix.env()),
      dialyzer: [
        plt_add_apps: [:mix, :ex_unit, :ekv],
        plt_core_path: "priv/plts",
        plt_local_path: "priv/plts"
      ],
      start_permanent: Mix.env() == :prod,
      # Tests implement the host's seams in their own modules.
      consolidate_protocols: Mix.env() != :test,
      deps: deps()
    ]
  end

  def application, do: [extra_applications: [:logger]]

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  # priv/plts is the dialyzer cache, not the package's.
  defp package do
    [
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => @source_url},
      files:
        ~w(lib priv/v1 priv/openapi.json priv/openapi.bundled.json .formatter.exs mix.exs README.md LICENSE)
    ]
  end

  defp deps do
    [
      {:req_llm, "~> 1.21"},

      # Durability and fleet: agents that survive a node, and a cluster-wide
      # view of who is running.
      {:durable_server, "~> 0.1.5"},
      {:group, "~> 0.2.1"},
      # The time zones schedules and budget periods are read in.
      {:tz, "~> 0.28"},
      # The store on each node's disk, which an application adds itself. Core's
      # suite keeps its fleet in it, as a release does.
      {:ekv, "~> 0.4.3", optional: true},
      # Test only: stands in for a module a test has no seam to replace.
      {:mimic, "~> 1.7", only: :test},
      # The JSON Schemas in priv/: what operations take, which the catalog's
      # surfaces describe them by, and what the codec writes.
      {:jsv, "~> 0.23"},
      {:wardrik_precommit, path: "../../tools/precommit", only: [:dev, :test], runtime: false}
    ]
  end
end
