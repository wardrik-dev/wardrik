defmodule Mix.Tasks.Precommit do
  @shortdoc "Runs the checks a change to this package passes before it is pushed"
  @moduledoc """
  Runs this package's checks in three groups, lint, test and dialyzer, each
  step in an OS process of its own so a step that halts or raises cannot take
  the rest down with it.

      mix precommit                 every group, fixing what can be fixed in place
      mix precommit --check         verifying instead: a fixing step fails on what it would fix
      mix precommit --only test     one group

  CI runs each group as `mix precommit --check --only <group>`.

  A package adds steps of its own, or leaves some out, under `:precommit` in
  its `project/0`. A step is the arguments to `mix`, or a `{step, check}` pair
  where `--check` runs a different one:

      precommit: [
        lint: [{["wardrik.docs"], ["wardrik.docs", "--check"]}],
        skip: ["dialyzer"]
      ]
  """

  use Mix.Task

  @groups [
    lint: [
      {["deps.unlock", "--unused"], ["deps.unlock", "--check-unused"]},
      {["format"], ["format", "--check-formatted"]},
      ["credo", "--strict"],
      ["ex_dna", "--max-clones", "0"],
      ["reach.check", "--arch", "--smells", "--strict"]
    ],
    test: [
      ["test", "--warnings-as-errors", "--cover", "--export-coverage", "default"],
      # `--export-coverage` only writes the data; test.coverage is what applies
      # the threshold, and crap reads the same exported coverdata.
      ["test.coverage"],
      ["crap", "--verbose"]
    ],
    dialyzer: [
      ["dialyzer"]
    ]
  ]

  # Steps that need :test-only deps or read cover/default.coverdata. Passing
  # MIX_ENV explicitly overrides Mix's own preferred_cli_env, so these have to
  # be named rather than left to default.
  @test_env_tasks ~w(test test.coverage crap)

  @impl Mix.Task
  def run(args) do
    {opts, rest} = OptionParser.parse!(args, strict: [check: :boolean, only: :string])

    if rest != [], do: Mix.raise("usage: mix precommit [--check] [--only GROUP]")

    config = Mix.Project.config()[:precommit] || []

    steps =
      config
      |> groups()
      |> only(opts[:only])
      |> Enum.flat_map(fn {_group, steps} -> steps end)
      |> Enum.map(&pick(&1, opts[:check]))
      |> Enum.reject(fn [task | _] -> task in Keyword.get(config, :skip, []) end)

    case Enum.reject(steps, &run_step/1) do
      [] -> Mix.shell().info([:green, "\nprecommit: all steps passed", :reset])
      failed -> Mix.raise("precommit failed: #{Enum.map_join(failed, ", ", &hd/1)}")
    end
  end

  defp groups(config) do
    Enum.map(@groups, fn {group, steps} -> {group, steps ++ Keyword.get(config, group, [])} end)
  end

  defp only(groups, nil), do: groups

  defp only(groups, only) do
    case Enum.filter(groups, fn {group, _steps} -> Atom.to_string(group) == only end) do
      [] -> Mix.raise("no precommit group #{only}, expected one of lint, test, dialyzer")
      groups -> groups
    end
  end

  defp pick({_fix, check}, true), do: check
  defp pick({fix, _check}, _check?), do: fix
  defp pick(step, _check?), do: step

  defp run_step([task | _] = step) do
    Mix.shell().info([:cyan, "\n==> mix #{Enum.join(step, " ")}", :reset])

    {_output, status} =
      System.cmd("mix", step,
        env: env(task),
        into: IO.stream(:stdio, :line),
        stderr_to_stdout: true
      )

    if status != 0,
      do: Mix.shell().info([:red, "==> mix #{task} failed (exit #{status})", :reset])

    status == 0
  end

  defp env(task) do
    mix_env = if task in @test_env_tasks, do: "test", else: to_string(Mix.env())
    env = [{"MIX_ENV", mix_env}]

    if IO.ANSI.enabled?(),
      do: [{"ELIXIR_ERL_OPTIONS", "-elixir ansi_enabled true"} | env],
      else: env
  end
end
