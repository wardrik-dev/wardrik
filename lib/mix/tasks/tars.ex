defmodule Mix.Tasks.Tars do
  @shortdoc "Boot the Tars TUI"

  @moduledoc """
  Starts an agent and attaches `Tars.TUI` to it.

      mix tars
      mix tars --verbose
      mix tars --model anthropic:claude-sonnet-5
      mix tars --log /tmp/tars.log

  `--verbose` prints every event the turn loop publishes as its own line —
  chunks, tool calls, turn boundaries — instead of rendering the answer as
  chat. Useful for seeing what the agent is actually doing.

  Console logging is removed before the app starts, because `Owl.LiveScreen`
  repaints on a timer and any `Logger` write to the same device tears the
  frame. Pass `--log FILE` (or set `TARS_LOG`) to keep the messages — without
  it, `Logger.error("Turn crashed: …")` goes nowhere.
  """

  use Mix.Task

  alias Tars.LLM

  @impl Mix.Task
  def run(argv) do
    {opts, _argv} =
      OptionParser.parse!(argv, strict: [model: :string, log: :string, verbose: :boolean])

    Mix.Task.run("app.start")

    # After app.start, not before: starting the :logger application installs
    # the default handler, so removing it earlier is undone.
    silence_console_logging()
    redirect_logging(opts[:log] || System.get_env("TARS_LOG"))

    agent_id = :tars_tui
    config = config(opts[:model])
    {:ok, _agent} = Tars.Agent.Supervisor.start(agent_id, config: config)

    # The agent is named, so its event id is that name rather than its pid.
    {:ok, tui} =
      Tars.TUI.start_link(
        agent: agent_id,
        agent_id: agent_id,
        model: config.model_spec,
        verbose: opts[:verbose] || false,
        width: Owl.IO.columns() || 100
      )

    await(tui)
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

  defp config(nil), do: LLM.Config.new()
  defp config(model), do: LLM.Config.new(model_spec: model)

  defp await(tui) do
    ref = Process.monitor(tui)

    receive do
      {:DOWN, ^ref, :process, ^tui, _reason} -> :ok
    end
  end
end
