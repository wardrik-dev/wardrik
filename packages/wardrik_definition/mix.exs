defmodule WardrikDefinition.MixProject do
  use Mix.Project

  @version "0.1.0-rc.1"
  @source_url "https://github.com/wardrik-dev/wardrik"

  def project do
    [
      app: :wardrik_definition,
      version: @version,
      elixir: "~> 1.20",
      description:
        "Wardrik agent definitions, from an agent file or the HTTP API, read into the spec an agent runs on.",
      source_url: @source_url,
      package: [licenses: ["Apache-2.0"], links: %{"GitHub" => @source_url}],
      dialyzer: [
        plt_add_apps: [:mix, :ex_unit],
        plt_core_path: "priv/plts",
        plt_local_path: "priv/plts"
      ],
      start_permanent: Mix.env() == :prod,
      consolidate_protocols: Mix.env() != :test,
      deps: deps()
    ]
  end

  def application, do: [extra_applications: [:logger]]

  defp deps do
    [
      sibling(:wardrik_core),
      sibling(:wardrik_policy),
      sibling(:wardrik_trigger),
      sibling(:wardrik_workspace),
      sibling(:wardrik_notify),
      # The schema of a definition, whose keys are read as this compiles.
      sibling(:wardrik_protocol, runtime: false),
      {:yaml_elixir, "~> 2.12"},
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
