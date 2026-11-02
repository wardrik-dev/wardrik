defmodule WardrikDaemon.CLI do
  @moduledoc """
  The `wardrik` command, also installed as `rik`.

      wardrik agent ls
      wardrik ask triage "What's new?"
      wardrik approval approve triage CALL --json

    * Each command calls the daemon's HTTP API with the token in `cli_token`.
      `WARDRIK_URL` and `WARDRIK_TOKEN` point it at another daemon.
    * Every command takes `--json`.
    * An agent is a name: `triage` in the deployment's org, or `growth/triage` in another.
    * Commands on an agent take `--conversation ID`.
    * `serve`, `start`, `stop`, `pid`, `logs` and `service` are run by the `bin/wardrik` script.
  """

  alias WardrikDaemon.CLI.Access
  alias WardrikDaemon.CLI.Admin
  alias WardrikDaemon.CLI.Agents
  alias WardrikDaemon.CLI.Approvals
  alias WardrikDaemon.CLI.Command
  alias WardrikDaemon.CLI.Context
  alias WardrikDaemon.CLI.Help
  alias WardrikDaemon.CLI.Servers
  alias WardrikDaemon.CLI.Tokens
  alias WardrikDaemon.CLI.Triggers

  @always [json: :boolean, help: :boolean]

  @doc "Returns every command, in the order help lists them within each group."
  @spec commands() :: [Command.t()]
  def commands,
    do:
      Admin.commands() ++
        Agents.commands() ++
        Approvals.commands() ++
        Triggers.commands() ++ Servers.commands() ++ Access.commands() ++ Tokens.commands()

  @doc "Runs the command `argv` names, as `bin/wardrik` does, then halts the VM with its exit status."
  @spec halt([String.t()]) :: no_return()
  def halt(argv) do
    {:ok, _started} = Application.ensure_all_started([:req, :req_llm, :yaml_elixir, :owl])
    System.halt(main(argv))
  end

  @doc """
  Runs the command `argv` names. Returns the exit status.

  ## Options

    * `:env` - the environment. `System.get_env/0` unless set.
  """
  @spec main([String.t()], keyword()) :: 0 | 1
  def main(argv, opts \\ []) do
    cx = opts |> Keyword.get_lazy(:env, &System.get_env/0) |> Context.new()

    case cx |> routed(argv) |> ran(cx) do
      :ok -> 0
      {:error, why} -> failed(cx, why)
    end
  end

  defp failed(cx, why) do
    IO.puts(:stderr, "#{cx.program}: " <> why)
    1
  end

  defp routed(_cx, []), do: :help
  defp routed(_cx, ["help" | words]), do: {:help, words}

  defp routed(_cx, argv) do
    case found(argv) do
      {command, rest} -> {:command, command, rest}
      nil -> {:help, argv}
    end
  end

  defp found(argv) do
    commands()
    |> Enum.map(&matched(&1, argv))
    |> Enum.reject(&is_nil/1)
    |> Enum.max_by(fn {command, _rest} -> length(Command.words(command)) end, fn -> nil end)
  end

  defp matched(%Command{shortcut: shortcut} = command, [shortcut | rest]) when shortcut != nil,
    do: {command, rest}

  defp matched(command, argv) do
    words = Command.words(command)
    if Enum.take(argv, length(words)) == words, do: {command, Enum.drop(argv, length(words))}
  end

  defp ran(:help, cx), do: Help.all(cx, commands())
  defp ran({:help, []}, cx), do: Help.all(cx, commands())

  defp ran({:help, words}, cx) do
    case {found(words), under(words)} do
      {{command, []}, _namespace} -> Help.command(cx, command)
      {_found, [_ | _] = listed} -> Help.namespace(cx, Enum.join(words, " "), listed)
      _neither -> {:error, "#{Enum.join(words, " ")} isn't a command. See #{cx.program} help."}
    end
  end

  defp ran({:command, command, rest}, cx) do
    {flags, args, invalid} = OptionParser.parse(rest, strict: command.switches ++ @always)
    flags = Map.new(flags)
    run(command, args, flags, invalid, %{cx | json?: Map.get(flags, :json, false)})
  end

  defp run(command, _args, %{help: true}, _invalid, cx), do: Help.command(cx, command)

  defp run(_command, _args, _flags, [{flag, _value} | _rest], cx),
    do: {:error, "#{flag} isn't an option of that command. See #{cx.program} help."}

  defp run(%Command{run: nil} = command, _args, _flags, [], cx),
    do: {:error, "The #{cx.program} script runs that itself: #{cx.program} #{command.name}"}

  defp run(command, args, flags, [], cx) do
    if Command.takes?(command, length(args)),
      do: command.run.(args, flags, cx),
      else: {:error, "Usage: #{cx.program} #{Command.usage(command)}"}
  end

  defp under(words) do
    Enum.filter(commands(), fn command ->
      Enum.take(Command.words(command), length(words)) == words and
        length(Command.words(command)) > length(words)
    end)
  end
end
