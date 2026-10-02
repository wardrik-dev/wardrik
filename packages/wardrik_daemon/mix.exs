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
        "The Wardrik daemon: agent files, config.yaml, the wardrik command, and what a release runs beside core.",
      source_url: @source_url,
      package: [licenses: ["Apache-2.0"], links: %{"GitHub" => @source_url}],
      elixirc_paths: elixirc_paths(Mix.env()),
      dialyzer: [
        plt_add_apps: [:mix, :ex_unit],
        plt_core_path: "priv/plts",
        plt_local_path: "priv/plts"
      ],
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      precommit: [
        # The docs site's reference pages, written from the code.
        lint: [{["wardrik.docs"], ["wardrik.docs", "--check"]}]
      ]
    ]
  end

  def application, do: [extra_applications: [:logger]]

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(:dev), do: ["lib", "dev"]
  defp elixirc_paths(_env), do: ["lib"]

  defp deps do
    [
      sibling(:wardrik),
      sibling(:wardrik_brave),
      sibling(:wardrik_console),
      sibling(:wardrik_ecto),
      sibling(:wardrik_http),
      sibling(:wardrik_lua),
      sibling(:wardrik_mcp),
      sibling(:wardrik_notify),
      sibling(:wardrik_oauth),
      sibling(:wardrik_policy),
      sibling(:wardrik_research),
      sibling(:wardrik_s3),
      sibling(:wardrik_vault),
      sibling(:wardrik_workspace),
      {:yaml_elixir, "~> 2.12"},
      {:owl, "~> 0.13"},
      # The store a daemon keeps where config.yaml names none.
      {:ekv, "~> 0.4.3"},
      # What serves the TUI over SSH, where the release carries it.
      {:termite_ssh, "~> 0.1.2", optional: true},
      # The TUI the SSH tests serve, as a release that carries it does.
      sibling(:wardrik_tui, only: :test),
      {:mimic, "~> 1.7", only: :test},
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
