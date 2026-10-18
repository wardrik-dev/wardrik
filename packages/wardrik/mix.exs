defmodule Wardrik.MixProject do
  use Mix.Project

  @version "0.1.0-rc.1"
  @source_url "https://github.com/wardrik-dev/wardrik"

  def project do
    [
      app: :wardrik,
      version: @version,
      elixir: "~> 1.20",
      description:
        "Agents inside your Elixir application: their definitions, policies, triggers, files, credentials and notices, kept in its store and started in its tree.",
      source_url: @source_url,
      package: [licenses: ["Apache-2.0"], links: %{"GitHub" => @source_url}],
      docs: docs(),
      elixirc_paths: elixirc_paths(Mix.env()),
      dialyzer: [
        plt_add_apps: [:mix, :ex_unit, :ecto_sql, :ekv],
        plt_core_path: "priv/plts",
        plt_local_path: "priv/plts"
      ],
      start_permanent: Mix.env() == :prod,
      # Tests implement the host's seams in their own modules.
      consolidate_protocols: Mix.env() != :test,
      deps: deps()
    ]
  end

  def application,
    do: [
      extra_applications: [:logger, :crypto],
      env: [
        wardrik_trigger_sources: [feed: WardrikTrigger.Feed],
        wardrik_trigger_verifiers: [
          shared: WardrikTrigger.Webhook.Shared,
          standard: WardrikTrigger.Webhook.Standard
        ]
      ]
    ]

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  # guides/policies.md is the docs site's reference page too: mix
  # wardrik.docs writes it there.
  defp docs do
    [
      main: "readme",
      extras: [
        "README.md",
        "guides/definition.md",
        "guides/policy.md",
        "guides/policies.md",
        "guides/triggers.md",
        "guides/workspace.md",
        "guides/notify.md",
        "guides/vault.md",
        "guides/postgres.md",
        "guides/s3.md",
        "guides/workflow.md",
        "guides/research.md"
      ],
      groups_for_extras: [Guides: ~r"guides/"]
    ]
  end

  defp deps do
    [
      {:ex_doc, "~> 0.40", only: :dev, runtime: false},
      {:makeup_syntect, "~> 0.1", only: :dev, runtime: false},
      sibling(:wardrik_core),
      {:durable_server, "~> 0.1.5"},
      {:group, "~> 0.2.1"},
      {:req, "~> 0.7"},
      # Feeds a trigger watches, read as RSS or Atom.
      {:sweet_xml, "~> 0.7"},
      # Agent files' frontmatter.
      {:yaml_elixir, "~> 2.12"},
      # The stores an application may name, each of which it adds itself: on
      # each node's disk, or in Postgres through its own repo.
      {:ekv, "~> 0.4.3", optional: true},
      {:ecto_sql, "~> 3.14", optional: true},
      {:postgrex, "~> 0.22.4", optional: true},
      {:nimble_options, "~> 1.1"},
      {:mimic, "~> 1.7", only: :test},
      {:plug, "~> 1.16", only: :test},
      {:wardrik_precommit, path: "../../tools/precommit", only: [:dev, :test], runtime: false}
    ]
  end

  # A package beside this one in this repository: by path while it is here,
  # and by version where this one is built for Hex, with WARDRIK_HEX=1, or
  # fetched from it.
  defp sibling(app, opts \\ []) do
    if System.get_env("WARDRIK_HEX") != "1" and Path.basename(Path.dirname(__DIR__)) == "packages",
      do: {app, [path: "../#{app}"] ++ opts},
      else: {app, "~> #{@version}", opts}
  end
end
