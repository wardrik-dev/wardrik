defmodule Wardrik.MixProject do
  use Mix.Project

  @source_url "https://github.com/wardrik-dev/wardrik"

  def project do
    [
      app: :wardrik,
      version: "0.1.0-rc.1",
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
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :os_mon],
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
      files: ~w(lib priv/protocol .formatter.exs mix.exs README.md LICENSE)
    ]
  end

  defp deps do
    [
      {:req_llm, "~> 1.21"},

      # Durability and fleet: agents that survive a node, and a cluster-wide
      # view of who is running.
      {:durable_server, "~> 0.1.5"},
      {:group, "~> 0.2.1"},
      # The store where no adapter is configured. Optional, so a host that keeps
      # its store in Postgres or S3 never compiles its SQLite NIF.
      {:ekv, "~> 0.4.3", optional: true},
      # Test only, and in dev for dialyzer: Wardrik.Test.LLMStub stubs with it.
      {:mimic, "~> 1.7", only: [:dev, :test]},
      {:wardrik_precommit, path: "../../tools/precommit", only: [:dev, :test], runtime: false}
    ]
  end
end
