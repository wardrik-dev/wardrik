defmodule WardrikStore.MixProject do
  use Mix.Project

  @version "0.1.0-rc.1"
  @source_url "https://github.com/wardrik-dev/wardrik"

  def project do
    [
      app: :wardrik_store,
      version: @version,
      elixir: "~> 1.20",
      description:
        "Where Wardrik keeps agents and their records: the store behaviour, its EKV and in-memory adapters, and the suite an adapter passes.",
      source_url: @source_url,
      package: [licenses: ["Apache-2.0"], links: %{"GitHub" => @source_url}],
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

  defp deps do
    [
      {:durable_server, "~> 0.1.5"},
      # The store where no adapter is configured. Optional, so a host that
      # keeps its store in Postgres or S3 never compiles its SQLite NIF.
      {:ekv, "~> 0.4.3", optional: true},
      {:mimic, "~> 1.7", only: :test},
      {:wardrik_precommit, path: "../../tools/precommit", only: [:dev, :test], runtime: false}
    ]
  end
end
