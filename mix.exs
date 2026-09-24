defmodule Tars.MixProject do
  use Mix.Project

  @source_url "https://github.com/jonlunsford/tars"

  def project do
    [
      app: :tars,
      version: "0.1.0",
      elixir: "~> 1.20",
      description: "An agent runtime built on OTP.",
      source_url: @source_url,
      package: package(),
      releases: releases(),
      aliases: aliases(),
      elixirc_paths: elixirc_paths(Mix.env()),
      dialyzer: [
        plt_add_apps: [:mix, :ex_unit],
        plt_core_path: "priv/plts",
        plt_local_path: "priv/plts"
      ],
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

  defp package do
    [
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => @source_url}
    ]
  end

  # One release carrying its own ERTS. `bin/tarsd` is the node's own script
  # and `bin/tars`, from rel/overlays, the command a person runs.
  # `rel/env.sh.eex` gives each install a cookie of its own and keeps
  # distribution on loopback.
  defp releases do
    [
      tarsd: [
        include_executables_for: [:unix],
        applications: [tars: :permanent],
        steps: [:assemble, :tar]
      ]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:req_llm, "~> 1.21"},

      # Used by lib/tars_lua, not by core. A Lua 5.3 VM in pure Elixir: no
      # NIFs, so it ships anywhere the release does.
      {:lua, "~> 1.0"},

      # Durability and fleet: agents that survive a node, and a cluster-wide
      # view of who is running.
      {:durable_server, "~> 0.1.5"},
      {:group, "~> 0.2.1"},
      {:ekv, "~> 0.4.3"},

      # Used by lib/tars_tui, not by core. Pinned: pre-1.0. termite_ssh serves
      # the TUI over SSH, a session per client.
      {:breeze, "0.5.1"},
      {:termite_ssh, "~> 0.1.2"},

      # Used by the bolt-on tool packages under lib/tars_brave, not by core.
      {:req, "~> 0.7"},

      # Used by lib/tars_mcp, not by core. The MCP client: transports, the
      # protocol, and the callbacks a server calls back through. Its HTTP
      # transport expects a Finch pool that it does not start, so we name it
      # here and `TarsMCP.Supervisor` starts it.
      {:anubis_mcp, "~> 2.0"},
      {:finch, "~> 0.23"},

      # Used by lib/tars_daemon, not by core: the daemon's config.yaml, and the
      # frontmatter of its agent files. yamerl underneath is pure Erlang.
      {:yaml_elixir, "~> 2.12"},

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

  # Grouped so CI can run each group on a runner of its own; locally they run
  # in this order.
  @precommit_groups [
    lint: [
      ["deps.unlock", "--unused"],
      ["format"],
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

  defp aliases do
    [
      precommit: &precommit/1
    ]
  end

  # `--check` verifies instead of rewriting: the steps that fix files in place
  # fail on what they would have fixed. `--only` runs one group. CI runs each
  # group as `mix precommit --check --only <group>`.
  @check_steps %{
    ["deps.unlock", "--unused"] => ["deps.unlock", "--check-unused"],
    ["format"] => ["format", "--check-formatted"]
  }

  defp precommit(args) do
    {opts, rest} = OptionParser.parse!(args, strict: [check: :boolean, only: :string])

    if rest != [], do: Mix.raise("usage: mix precommit [--check] [--only GROUP]")

    steps =
      opts[:only]
      |> precommit_groups()
      |> Enum.flat_map(fn {_group, steps} -> steps end)
      |> Enum.map(&if(opts[:check], do: Map.get(@check_steps, &1, &1), else: &1))

    case Enum.filter(steps, &(not run_step(&1))) do
      [] ->
        Mix.shell().info([:green, "\nprecommit: all steps passed", :reset])

      steps ->
        Mix.raise("precommit failed: #{Enum.map_join(steps, ", ", &hd/1)}")
    end
  end

  defp precommit_groups(nil), do: @precommit_groups

  defp precommit_groups(only) do
    case Enum.filter(@precommit_groups, fn {group, _steps} -> Atom.to_string(group) == only end) do
      [] -> Mix.raise("no precommit group #{only}, expected one of #{group_names()}")
      groups -> groups
    end
  end

  defp group_names, do: Enum.map_join(@precommit_groups, ", ", fn {group, _} -> group end)

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
