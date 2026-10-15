defmodule Wardrik.MixProject do
  use Mix.Project

  @version "0.1.0-rc.1"
  @source_url "https://github.com/wardrik-dev/wardrik"

  def project do
    [
      app: :wardrik,
      version: @version,
      elixir: "~> 1.20",
      description: "An agent runtime built on OTP.",
      source_url: @source_url,
      package: package(),
      elixirc_paths: elixirc_paths(Mix.env()),
      dialyzer: [
        plt_add_apps: [:mix, :ex_unit, :mimic],
        plt_core_path: "priv/plts",
        plt_local_path: "priv/plts"
      ],
      start_permanent: Mix.env() == :prod,
      # Tests implement the host's seams in their own modules.
      consolidate_protocols: Mix.env() != :test,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Wardrik.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  # priv/plts is the dialyzer cache, not the package's.
  defp package do
    [
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib .formatter.exs mix.exs README.md LICENSE)
    ]
  end

  defp deps do
    [
      {:req_llm, "~> 1.21"},

      # Durability and fleet: agents that survive a node, and a cluster-wide
      # view of who is running.
      {:durable_server, "~> 0.1.5"},
      {:group, "~> 0.2.1"},
      # Where agents and their records are kept.
      sibling(:wardrik_store),
      # The store core's suite keeps its fleet in, as a release does.
      {:ekv, "~> 0.4.3", only: :test},
      # Test only, and in dev for dialyzer: Wardrik.Test.LLMStub stubs with it.
      {:mimic, "~> 1.7", only: [:dev, :test]},
      # The schemas of what operations take, which the catalog's surfaces
      # describe them by, and the codec's tests check what it writes against.
      sibling(:wardrik_protocol),
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
