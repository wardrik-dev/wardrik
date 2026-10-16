defmodule WardrikProtocol.MixProject do
  use Mix.Project

  @version "0.1.0-rc.1"
  @source_url "https://github.com/wardrik-dev/wardrik"

  def project do
    [
      app: :wardrik_protocol,
      version: @version,
      elixir: "~> 1.20",
      description: "The JSON Schemas of Wardrik's events and HTTP API.",
      source_url: @source_url,
      package: package(),
      dialyzer: [
        plt_add_apps: [:mix, :ex_unit],
        plt_core_path: "priv/plts",
        plt_local_path: "priv/plts"
      ],
      deps: deps()
    ]
  end

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
      {:jsv, "~> 0.23"},
      {:wardrik_precommit, path: "../../tools/precommit", only: [:dev, :test], runtime: false}
    ]
  end
end
