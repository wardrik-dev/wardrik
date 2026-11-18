defmodule WardrikResearch.MixProject do
  use Mix.Project

  def project do
    [
      app: :wardrik_research,
      version: "0.1.0-rc.3",
      elixir: "~> 1.20",
      description:
        "Deep research for agents: a topic split across angles, a subagent researching each at once, and one report from what they found.",
      package: package(),
      docs: [
        main: "readme",
        skip_undefined_reference_warnings_on: ["CHANGELOG.md"],
        extras: ["README.md", "CHANGELOG.md"]
      ],
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      aliases: aliases(),
      dialyzer: [
        plt_add_apps: [:mix, :ex_unit],
        plt_core_path: "priv/plts",
        plt_local_path: "priv/plts",
        # Sibling packages are path deps, which mix.lock leaves out. They're analysed with this one
        # instead of kept in the PLT, so the PLT is current whenever mix.lock is.
        plt_ignore_apps: siblings(),
        paths: Enum.map([:wardrik_research | siblings()], &"_build/#{Mix.env()}/lib/#{&1}/ebin")
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

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp package do
    [
      licenses: ["Apache-2.0"],
      links: %{
        "GitHub" => "https://github.com/wardrik-dev/wardrik/tree/main/extensions/wardrik_research"
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
        # In a VM of its own: in the tests' VM, stopping their cover first takes half a minute in CI.
        "cmd env MIX_ENV=test mix test.coverage",
        "crap",
        "dialyzer"
      ]
    ]
  end

  defp deps do
    [
      sibling(:wardrik_core, "~> 0.1.0-rc.8"),
      {:mimic, "~> 2.4", only: :test},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_slop, "~> 0.4", only: [:dev, :test], runtime: false},
      {:ex_dna, "~> 1.5", only: [:dev, :test], runtime: false},
      {:ex_crap, "~> 0.1.0", only: [:dev, :test], runtime: false},
      {:reach, "~> 2.8", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  # The sibling packages it depends on, directly or through each other. Each mix.exs names its own.
  defp siblings, do: if(System.get_env("WARDRIK_HEX"), do: [], else: reached(__DIR__, []))

  defp reached(dir, seen) do
    ~r/sibling\(:(\w+)/
    |> Regex.scan(File.read!(Path.join(dir, "mix.exs")), capture: :all_but_first)
    |> Enum.map(fn [name] -> String.to_atom(name) end)
    |> Enum.reduce(seen, fn name, seen ->
      if name in seen, do: seen, else: reached(sibling_path(name), [name | seen])
    end)
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
