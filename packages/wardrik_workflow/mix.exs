defmodule WardrikWorkflow.MixProject do
  use Mix.Project

  @version "0.1.0-rc.1"
  @source_url "https://github.com/wardrik-dev/wardrik"

  def project do
    [
      app: :wardrik_workflow,
      version: @version,
      elixir: "~> 1.20",
      description:
        "Workflows for Wardrik agents: steps run many at once or in order, each under a span of its own, and offered to an agent as a tool.",
      source_url: @source_url,
      package: [licenses: ["Apache-2.0"], links: %{"GitHub" => @source_url}],
      elixirc_paths: elixirc_paths(Mix.env()),
      dialyzer: [
        plt_add_apps: [:mix, :ex_unit],
        plt_core_path: "priv/plts",
        plt_local_path: "priv/plts"
      ],
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application, do: [extra_applications: [:logger]]

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp deps do
    [
      sibling(:wardrik_core),
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
