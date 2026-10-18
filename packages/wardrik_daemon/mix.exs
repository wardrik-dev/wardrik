defmodule WardrikDaemon.MixProject do
  use Mix.Project

  @version "0.1.0-rc.1"
  @source_url "https://github.com/wardrik-dev/wardrik"

  def project do
    [
      app: :wardrik_daemon,
      version: @version,
      elixir: "~> 1.20",
      description:
        "The Wardrik daemon: agent files, config.yaml, the wardrik command, and the release that runs them.",
      source_url: @source_url,
      package: [licenses: ["Apache-2.0"], links: %{"GitHub" => @source_url}],
      docs: docs(),
      elixirc_paths: elixirc_paths(Mix.env()),
      dialyzer: [
        plt_add_apps: [:mix, :ex_unit],
        plt_core_path: "priv/plts",
        plt_local_path: "priv/plts"
      ],
      start_permanent: Mix.env() == :prod,
      # Tests implement the host's seams in their own modules.
      consolidate_protocols: Mix.env() != :test,
      deps: deps(),
      releases: releases(),
      # The application is the release's tree, which reads config.yaml. The
      # suite starts what it depends on, and the trees it needs, itself.
      aliases: [test: "test --no-start"],
      test_coverage: [summary: [threshold: 89]],
      precommit: [
        # The docs site's reference pages, written from this package's code
        # and the HTTP API's, policies' and the protocol's schemas, so checked
        # with the tests a change to any of them runs.
        test: [{["wardrik.docs"], ["wardrik.docs", "--check"]}]
      ]
    ]
  end

  def application, do: [extra_applications: [:logger], mod: {WardrikDaemon.Application, []}]

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(:dev), do: ["lib", "dev"]
  defp elixirc_paths(_env), do: ["lib"]

  # The guides are the docs site's reference pages too: mix wardrik.docs
  # writes them there.
  defp docs do
    [
      main: "readme",
      extras: ["README.md", "guides/config.md", "guides/agent-files.md"],
      groups_for_extras: [Reference: ~r"guides/"]
    ]
  end

  defp deps do
    [
      {:ex_doc, "~> 0.40", only: :dev, runtime: false},
      {:makeup_syntect, "~> 0.1", only: :dev, runtime: false},
      sibling(:wardrik_core),
      sibling(:wardrik),
      sibling(:wardrik_brave),
      sibling(:wardrik_http),
      sibling(:wardrik_lua),
      sibling(:wardrik_mcp),
      sibling(:wardrik_channel),
      sibling(:wardrik_oauth),
      {:yaml_elixir, "~> 2.12"},
      {:owl, "~> 0.13"},
      # The store a daemon keeps where config.yaml names none.
      {:ekv, "~> 0.4.3"},
      # Postgres, the store config.yaml may name instead, which wardrik leaves
      # to the application.
      {:ecto_sql, "~> 3.14"},
      {:postgrex, "~> 0.22.4"},
      # What serves the TUI over SSH.
      {:termite_ssh, "~> 0.1.2"},
      # The console the CLI prints with, and the TUI the SSH tests serve, as a
      # release that carries it does.
      sibling(:wardrik_tui),
      # What the release ships that the daemon's own code never names: the
      # channels config.yaml may set up.
      sibling(:wardrik_slack),
      {:mimic, "~> 1.7", only: :test},
      {:wardrik_precommit, path: "../../tools/precommit", only: [:dev, :test], runtime: false}
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
        steps: [:assemble, :tar]
      ]
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
