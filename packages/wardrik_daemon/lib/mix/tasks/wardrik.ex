defmodule Mix.Tasks.Wardrik do
  @shortdoc "Runs the wardrik command from source"
  @moduledoc """
  Runs the `wardrik` command from source, without a release.

      # Runs the daemon in the foreground
      mix wardrik serve

      # Runs any other command, as the release's `bin/wardrik` does
      mix wardrik ask assistant "What's on today?"
  """

  use Mix.Task

  @impl Mix.Task
  def run(["serve"]) do
    System.put_env("WARDRIK_SERVE", "1")
    Mix.Task.run("run", ["--no-halt"])
  end

  def run(argv) do
    {:ok, _started} = Application.ensure_all_started([:req, :req_llm, :yaml_elixir, :owl])

    case WardrikDaemon.CLI.main(argv) do
      0 -> :ok
      status -> exit({:shutdown, status})
    end
  end
end
