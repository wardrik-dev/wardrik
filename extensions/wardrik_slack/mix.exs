defmodule WardrikSlack.MixProject do
  use Mix.Project

  def project do
    [
      app: :wardrik_slack,
      version: "0.1.0-rc.5",
      elixir: "~> 1.20",
      description:
        "Wardrik in Slack: agents answer in threads, and ask there, with Approve and Deny, before a call they can't make alone.",
      package: package(),
      docs: [main: "readme", extras: ["README.md", "CHANGELOG.md"]],
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      test_coverage: [ignore_modules: [~r/^Wardrik\.Test\./]],
      aliases: aliases(),
      dialyzer: [
        plt_add_apps: [:mix, :ex_unit],
        plt_core_path: "priv/plts",
        plt_local_path: "priv/plts"
      ],
      deps: deps()
    ]
  end

  def cli, do: [preferred_envs: [precommit: :test]]

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # The Wardrik tests share Wardrik's own helpers for agents, owners and deciders.
  defp elixirc_paths(:test),
    do:
      ["lib", "test/support"] ++
        Enum.map(
          ~w(authorizers.ex directory.ex owned.ex channel/chat.ex),
          &Path.expand(&1, Path.join(__DIR__, "../../packages/wardrik/test/support"))
        )

  defp elixirc_paths(_env), do: ["lib"]

  defp package do
    [
      licenses: ["Apache-2.0"],
      links: %{
        "GitHub" => "https://github.com/wardrik-dev/wardrik/tree/main/extensions/wardrik_slack"
      },
      files: ~w(lib mix.exs README.md CHANGELOG.md LICENSE)
    ]
  end

  defp aliases do
    [
      precommit: [
        "deps.unlock --check-unused",
        "format --check-formatted",
        "credo --strict",
        "ex_dna --max-clones 0",
        "reach.check --arch --smells --strict",
        "test --warnings-as-errors --cover --export-coverage default",
        "test.coverage",
        "crap",
        "dialyzer --force-check"
      ]
    ]
  end

  defp deps do
    [
      sibling(:wardrik, "~> 0.1.0-rc.11"),
      {:nimble_options, "~> 1.1"},
      {:req, "~> 0.7"},
      {:websockex, "~> 0.5.1"},
      {:mimic, "~> 2.5", only: :test},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_slop, "~> 0.4", only: [:dev, :test], runtime: false},
      {:ex_dna, "~> 1.5", only: [:dev, :test], runtime: false},
      {:ex_crap, "~> 0.1.0", only: [:dev, :test], runtime: false},
      {:reach, "~> 2.8", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  # Wardrik's own packages come from this repository, or from Hex with WARDRIK_HEX=1, as when
  # publishing.
  defp sibling(name, requirement, opts \\ []) do
    if System.get_env("WARDRIK_HEX"),
      do: {name, requirement, opts},
      else: {name, Keyword.put(opts, :path, sibling_path(name))}
  end

  defp sibling_path(name), do: __DIR__ |> Path.join("../../*/#{name}") |> Path.wildcard() |> hd()
end
