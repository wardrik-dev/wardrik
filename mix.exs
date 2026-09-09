defmodule Tars.MixProject do
  use Mix.Project

  def project do
    [
      app: :tars,
      version: "0.1.0",
      elixir: "~> 1.20",
      aliases: aliases(),
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {Tars.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:req_llm, "~> 1.21"},
      {:owl, "~> 0.13.1"},

      # Test and dev
      # Dev deps
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_slop, "~> 0.4", only: [:dev, :test], runtime: false},
      {:ex_dna, "~> 1.5", only: [:dev, :test], runtime: false},
      {:ex_crap, "~> 0.1.0", only: [:dev, :test], runtime: false},
      {:reach, "~> 2.8", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:mimic, "~> 1.7", only: :test}
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
