defmodule Tars.MixProject do
  use Mix.Project

  def project do
    [
      app: :tars,
      version: "0.1.0",
      elixir: "~> 1.20",
      aliases: aliases(),
      elixirc_paths: elixirc_paths(Mix.env()),
      dialyzer: [plt_add_apps: [:mix]],
      test_coverage: [ignore_modules: ignored_modules()],
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger, :os_mon],
      mod: {Tars.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  # `dev/` holds the demo policy and tools used to drive the governance seams
  # from a terminal. Nothing in it ships.
  defp elixirc_paths(:dev), do: ["lib", "dev"]
  defp elixirc_paths(_env), do: ["lib"]

  # A thin shell over a real terminal. Excluded because covering it would mean
  # asserting on mocks of Mix rather than on any behaviour of ours.
  defp ignored_modules do
    [Mix.Tasks.Tars]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:req_llm, "~> 1.21"},

      # Used by lib/tars_tui, not by core. Pinned: pre-1.0.
      {:breeze, "0.5.1"},

      # Used by the bolt-on tool packages under lib/tars_brave, not by core.
      {:req, "~> 0.7"},

      # Test and dev
      # Dev deps
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_slop, "~> 0.4", only: [:dev, :test], runtime: false},
      {:ex_dna, "~> 1.5", only: [:dev, :test], runtime: false},
      {:ex_crap, "~> 0.1.0", only: [:dev, :test], runtime: false},
      {:reach, "~> 2.8", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:mimic, "~> 1.7", only: :test},
      # Req.Test answers stubs with a %Plug.Conn{}.
      {:plug, "~> 1.16", only: :test}
    ]
  end

  @precommit_steps [
    ["deps.unlock", "--unused"],
    ["format"],
    ["test", "--warnings-as-errors", "--cover", "--export-coverage", "default"],
    # `--export-coverage` only writes the data; test.coverage is what applies the
    # threshold, and crap reads the same exported coverdata.
    ["test.coverage"],
    ["crap", "--verbose"],
    ["credo", "--strict"],
    ["dialyzer"],
    ["ex_dna", "--max-clones", "0"],
    ["reach.check", "--smells", "--strict"]
  ]

  defp aliases do
    [
      precommit: &precommit/1
    ]
  end

  defp precommit(_args) do
    case Enum.filter(@precommit_steps, &(not run_step(&1))) do
      [] ->
        Mix.shell().info([:green, "\nprecommit: all steps passed", :reset])

      steps ->
        Mix.raise("precommit failed: #{Enum.map_join(steps, ", ", &hd/1)}")
    end
  end

  # Each step runs in its own OS process so a halting or raising task cannot
  # take the remaining steps down with it.
  defp run_step([task | _] = step) do
    Mix.shell().info([:cyan, "\n==> mix #{Enum.join(step, " ")}", :reset])

    {_output, status} =
      System.cmd("mix", step,
        env: step_env(task),
        into: IO.stream(:stdio, :line),
        stderr_to_stdout: true
      )

    if status != 0 do
      Mix.shell().info([:red, "==> mix #{task} failed (exit #{status})", :reset])
    end

    status == 0
  end

  # Steps that need :test-only deps (mimic) or read cover/default.coverdata.
  # Passing MIX_ENV explicitly overrides Mix's own preferred_cli_env, so these
  # have to be named rather than left to default.
  @test_env_tasks ~w(test test.coverage crap)

  defp step_env(task) do
    mix_env = if task in @test_env_tasks, do: "test", else: to_string(Mix.env())
    env = [{"MIX_ENV", mix_env}]

    if IO.ANSI.enabled?() do
      [{"ELIXIR_ERL_OPTIONS", "-elixir ansi_enabled true"} | env]
    else
      env
    end
  end
end
