defmodule Mix.Tasks.Tars do
  @shortdoc "Boot the Tars TUI"

  @default_tools [TarsBrave.WebSearch, TarsResearch.Deep]

  @moduledoc """
  Starts an agent and attaches the full-screen `TarsTUI.App` to it.

      mix tars
      mix tars --verbose
      mix tars --model anthropic:claude-sonnet-5
      mix tars --log /tmp/tars.log
      mix tars --tool TarsBrave.WebSearch --tool TarsResearch.Deep
      mix tars --no-tools
      mix tars --policy MyApp.Policy --user jon --org acme
      mix tars --timeout 600

  The agent boots with the tool packages this repo ships —
  `#{Enum.map_join(@default_tools, "`, `", &inspect/1)}` — because a turn with
  no tools exercises none of the tree. `--tool` names a different set, and
  `--no-tools` boots without any.

  `--policy` names a `Tars.Policy` module, and `--user` and `--org` say who the
  turn is for, which is what a policy reads to decide. A policy that answers
  `{:ask, prompt}` parks the turn; resume it from anywhere that can reach the
  node:

      Tars.Agent.resume(:tars_tui, %{"call_abc" => :approve})

  `--timeout` bounds a whole turn, in seconds.

  `--verbose` adds a trace line for the lower-level events — model requests,
  tool calls, metadata — and commits the model's reasoning to the transcript.
  `Ctrl-T` toggles the same thing while running.

  Console logging is removed before the app starts: the client draws frames on
  the terminal, and any `Logger` write to the same device lands in the middle
  of one. Pass `--log FILE` (or set `TARS_LOG`) to keep the messages —
  without it, `Logger.error("Turn crashed: …")` goes nowhere.
  """

  use Mix.Task

  alias Tars.LLM

  @impl Mix.Task
  def run(argv) do
    {opts, _argv} =
      OptionParser.parse!(argv,
        strict: [
          model: :string,
          log: :string,
          verbose: :boolean,
          tool: :keep,
          tools: :boolean,
          policy: :string,
          user: :string,
          org: :string,
          timeout: :integer
        ]
      )

    Mix.Task.run("app.start")

    # After app.start, not before: starting the :logger application installs
    # the default handler, so removing it earlier is undone.
    silence_console_logging()
    redirect_logging(opts[:log] || System.get_env("TARS_LOG"))

    agent_id = :tars_tui
    config = config(opts)

    {:ok, _agent} =
      Tars.Agent.Supervisor.start(agent_id, [config: config] ++ scope_opts(opts))

    :ok =
      Breeze.Server.run(
        view: TarsTUI.App,
        start_opts: [
          agent: agent_id,
          agent_id: agent_id,
          model: config.model_spec,
          verbose: opts[:verbose] || false
        ],
        global_keybindings: TarsTUI.App.keybindings(),
        mouse: true,
        logger: false,
        inspector: false
      )
  end

  defp silence_console_logging, do: :logger.remove_handler(:default)

  defp redirect_logging(nil), do: :ok

  defp redirect_logging(path) do
    :ok = File.mkdir_p!(Path.dirname(path))

    :logger.add_handler(:tars_file, :logger_std_h, %{
      config: %{file: String.to_charlist(path)},
      formatter: {:logger_formatter, %{single_line: true}}
    })
  end

  defp config(opts) do
    opts
    |> Keyword.take([:model])
    |> Enum.map(fn {:model, spec} -> {:model_spec, spec} end)
    |> Keyword.put(:tools, tools(opts))
    |> LLM.Config.new()
  end

  # Only what was actually given: an agent started with no policy and no
  # deadline should look exactly as it did before either existed.
  defp scope_opts(opts) do
    opts
    |> Keyword.take([:user, :org])
    |> put_new_option(:policy, opts[:policy], &Module.safe_concat([&1]))
    |> put_new_option(:timeout, opts[:timeout], &:timer.seconds/1)
  end

  defp put_new_option(opts, _key, nil, _cast), do: opts
  defp put_new_option(opts, key, value, cast), do: Keyword.put(opts, key, cast.(value))

  defp tools(opts) do
    if Keyword.get(opts, :tools, true), do: named(Keyword.get_values(opts, :tool)), else: []
  end

  defp named([]), do: @default_tools
  defp named(names), do: Enum.map(names, &Module.safe_concat([&1]))
end
