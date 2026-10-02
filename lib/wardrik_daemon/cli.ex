defmodule WardrikDaemon.CLI do
  @moduledoc """
  What `bin/wardrik` asks a running daemon, and what it says about commands
  when none answers.

  `commands/0` is every command `wardrik` takes, the script's own among them,
  and `wardrik help` lists them. `main/1` runs one the daemon answers, on the
  daemon's node, and prints its answer; a command that fails prints why and
  exits with status 1. `offline/1` answers the rest on a VM of its own: help,
  a name that is no command, and a command the daemon answers when no daemon
  is running. Both read the `WardrikDaemon.CLI.Terminal` the script describes
  ahead of the command's own arguments.

  A command that takes `--json` answers with one JSON document, in the shape
  the HTTP API answers with where it has one, and a command that fails with
  `--json` answers `{"error": {"type": ..., "message": ...}}`.

  A node waiting for a quorum of its cluster answers every command with what
  it is waiting for; see `WardrikDaemon.Cluster.waiting/0`.
  """

  alias Wardrik.Agent
  alias Wardrik.Fleet
  alias WardrikConsole.Nodes
  alias WardrikDaemon.CLI.Agents
  alias WardrikDaemon.CLI.Command
  alias WardrikDaemon.CLI.Completion
  alias WardrikDaemon.CLI.Decisions
  alias WardrikDaemon.CLI.Follow
  alias WardrikDaemon.CLI.Init
  alias WardrikDaemon.CLI.Terminal
  alias WardrikDaemon.CLI.Tokens
  alias WardrikDaemon.CLI.Turns
  alias WardrikDaemon.CLI.Vault
  alias WardrikDaemon.Cluster
  alias WardrikDaemon.Config
  alias WardrikHTTP.Resource
  alias WardrikPolicy.Pattern

  @faint [:faint, :light_black]

  @doc "Every command `wardrik` takes, in the order `wardrik help` lists them."
  @spec commands() :: [Command.t()]
  def commands do
    [
      Init.command(),
      %Command{name: "serve", summary: "run the daemon here, logging to the terminal"},
      %Command{name: "start", summary: "run the daemon in the background"},
      %Command{name: "stop", summary: "stop the daemon, and wait until it has"},
      %Command{
        name: "status",
        summary: "what the daemon, or its cluster, is running",
        details: ["With --json, the agents as GET /v1/agents lists them."],
        run: &status/2,
        json: &agents/2
      },
      %Command{name: "doctor", summary: "check what the daemon reads, running or not"},
      %Command{
        name: "reload",
        summary: "read the agent and policy files again, everywhere",
        run: &reload/2
      },
      %Command{
        name: "ask",
        arguments: "KEY MESSAGE",
        options: "[--no-wait]",
        summary: "send an agent a message, and follow its answer",
        details: [
          "It follows the turn as it goes, until it ends or waits on a person; Ctrl-C",
          "stops following, and the agent carries on. --no-wait only sends it."
        ],
        switches: [no_wait: :boolean],
        count: {2, :any},
        run: &ask/2,
        live: &answer_followed/3
      },
      %Command{
        name: "watch",
        arguments: "KEY",
        options: "[--json]",
        summary: "follow what an agent does, until Ctrl-C",
        details: [
          "With --json, each event as GET /v1/agents/KEY/events streams it, a line each."
        ],
        switches: [json: :boolean],
        count: {1, 1},
        run: &needs_terminal/2,
        live: &watch/3
      },
      %Command{
        name: "history",
        arguments: "KEY",
        summary: "what an agent has said",
        details: ["With --json, the agent as GET /v1/agents/KEY answers with it."],
        count: {1, 1},
        run: &history/2,
        json: &snapshot/2
      }
    ] ++
      Agents.commands() ++
      Decisions.commands() ++
      Turns.commands() ++ Tokens.commands() ++ Vault.commands() ++ script_commands()
  end

  # What bin/wardrik runs itself, listed for their help.
  defp script_commands do
    [
      %Command{name: "service install", summary: "run the daemon under your user's systemd"},
      %Command{name: "service uninstall", summary: "stop the service, and remove its unit"},
      %Command{name: "service status", summary: "how systemd has the service"},
      %Command{name: "service unit", summary: "print the unit install writes"},
      %Command{
        name: "attach",
        arguments: "[HOST]",
        summary: "the TUI, over SSH to HOST, localhost by default"
      },
      %Command{name: "remote", summary: "an IEx shell on the daemon"},
      %Command{name: "logs", summary: "follow the daemon's log"},
      %Command{name: "pid", summary: "the daemon's process id"},
      %Command{name: "version", summary: "print the version"},
      %Command{name: "help", arguments: "[COMMAND]", summary: "every command, or one in full"},
      %Command{
        name: "completion",
        arguments: "SHELL",
        summary: "completion for bash, zsh or fish, to install",
        details: [
          "It completes commands, options, and the keys and calls of the agents running.",
          "  wardrik completion bash > ~/.local/share/bash-completion/completions/wardrik",
          "  wardrik completion zsh > \"${fpath[1]}/_wardrik\"",
          "  wardrik completion fish > ~/.config/fish/completions/wardrik.fish"
        ]
      }
    ]
  end

  @doc """
  What `wardrik start` waits for: `""` once the agent files have been read, what
  the node is waiting for where it is waiting for its cluster, and a raise
  before either, or for a node the cluster does not name, which stops.
  """
  @spec started() :: String.t()
  def started do
    cond do
      Process.whereis(WardrikDaemon.Agents) ->
        _files = WardrikDaemon.Agents.files()
        ""

      reason = Cluster.refusal() ->
        raise reason

      reason = Cluster.waiting() ->
        reason

      true ->
        raise "wardrik is starting"
    end
  end

  @doc """
  What `wardrik stop` asks first: `""` where the node stops the usual way,
  writing down what it holds. A node that has lost its cluster's quorum can
  write down nothing, so it halts at once instead, as a node that crashed
  does, and the answer says so.
  """
  @spec stopping() :: String.t()
  def stopping do
    case Cluster.waiting() do
      nil ->
        ""

      reason ->
        {:ok, _timer} = :timer.apply_after(100, System, :halt, [0])

        reason <> ", so it can write down nothing it holds, and stops at once"
    end
  end

  @doc """
  Runs the command `args` name, on this node, as `bin/wardrik` asks over
  `erl_call`. A command that needs the terminal it came from exits with
  `{:shutdown, :live}` instead, and the script runs it again with `live/1`.
  """
  @spec main([String.t()]) :: :ok
  def main(args), do: args |> Terminal.read() |> dispatch()

  @doc """
  Runs the command `args` name live, as `bin/wardrik` asks over
  `bin/wardrikd rpc`. That evaluates it on this node under the group leader
  of the caller's own VM, so each line reaches the caller's terminal as it is
  written, and what a person types there can be read.
  """
  @spec live([String.t()]) :: :ok
  def live(args) do
    {terminal, args} = Terminal.read(args)
    dispatch({%{terminal | live?: true}, args})
  end

  # What a shell completing a word asks, which nothing else may answer.
  defp dispatch({_terminal, ["__complete" | words]}), do: complete(words, running())

  defp dispatch({terminal, args}) do
    case Cluster.waiting() do
      nil -> run(terminal, args)
      reason when args == ["status"] -> Terminal.puts(terminal, reason)
      reason -> failed(terminal, "unavailable", reason, "--json" in args)
    end
  end

  defp run(terminal, args) do
    with {:ok, %Command{run: run} = command, rest} when run != nil <-
           Command.find(commands(), args),
         {:ok, words, opts} <- Command.parse(command, rest),
         {:ok, words} <- named(command, words) do
      answer(terminal, command, words, opts)
    else
      {:error, usage} -> failed(terminal, "usage", usage, "--json" in args)
      not_a_command -> failed(terminal, "usage", unknown(not_a_command), "--json" in args)
    end
  end

  # A KEY or PREFIX, first among a command's arguments, may leave out the
  # deployment's org, as Wardrik.Fleet.expand/1 reads it.
  defp named(%Command{arguments: arguments}, [word | rest]) do
    expanded =
      cond do
        String.starts_with?(arguments, ["KEY", "[KEY"]) -> Fleet.expand(word)
        String.starts_with?(arguments, "[PREFIX") -> Fleet.expand_prefix(word)
        true -> {:ok, word}
      end

    with {:ok, word} <- expanded, do: {:ok, [word | rest]}
  end

  defp named(_command, []), do: {:ok, []}

  defp answer(terminal, %Command{} = command, words, opts) do
    json? = Keyword.get(opts, :json, false) and command.json != nil

    case respond(command, words, opts, terminal, json?) do
      {:ok, document} when json? -> IO.puts(JSON.encode!(document))
      {:ok, text} -> Terminal.puts(terminal, text)
      :ok -> :ok
      :live -> exit({:shutdown, :live})
      :error -> exit({:shutdown, 1})
      {:error, :usage} -> failed(terminal, "usage", Command.usage(command), json?)
      {:error, message} -> failed(terminal, "failed", message, json?)
    end
  end

  defp respond(%Command{json: json}, words, opts, _terminal, true), do: json.(words, opts)

  defp respond(%Command{run: run, live: live}, words, opts, terminal, false) do
    case run.(words, opts) do
      :live when terminal.live? -> live.(words, opts, terminal)
      answer -> answer
    end
  end

  # A command that fails prints why, or with --json an error of `type`
  # saying so, and exits with status 1.
  defp failed(terminal, type, message, json?) do
    if json?,
      do: IO.puts(JSON.encode!(Resource.error(type, plain(message)))),
      else: Terminal.puts(terminal, message)

    exit({:shutdown, 1})
  end

  defp plain(message),
    do: message |> WardrikConsole.Ansi.chardata(false) |> IO.chardata_to_string()

  @doc """
  What `bin/wardrik` asks a VM of its own for, when no daemon answers or for
  help, which it prints before halting: help to standard output with status
  0, and anything else to standard error with status 1.
  """
  @spec offline([String.t()]) :: no_return()
  def offline(args) do
    {terminal, args} = Terminal.read(args)
    System.halt(print_offline(args, terminal))
  end

  @doc """
  Prints what `offline/1` prints for `args`, and answers the status it exits
  with: what can follow the words a shell is completing, or `unanswered/2`'s
  answer, to standard output where it is help and to standard error where not.
  """
  @spec print_offline([String.t()], Terminal.t()) :: 0 | 1
  def print_offline(["__complete" | words], _terminal) do
    complete(words, %{keys: fn -> [] end, calls: fn _key -> [] end})
    0
  end

  def print_offline(args, terminal) do
    case unanswered(args, terminal) do
      {:ok, text} ->
        Terminal.puts(terminal, text)
        0

      {:error, text} ->
        Terminal.puts(terminal, text, :stderr)
        1
    end
  end

  @doc """
  What `offline/1` prints for `args`: help for `help` and whatever follows
  it, and otherwise why `args` name no command, or, for one the daemon
  answers, that no daemon is running.
  """
  @spec unanswered([String.t()], Terminal.t()) :: {:ok | :error, Owl.Data.t()}
  def unanswered(["help" | args], terminal), do: help(args -- ["-h", "--help"], terminal)
  def unanswered([], terminal), do: help([], terminal)

  def unanswered(["completion", shell], _terminal) do
    if shell in Completion.shells(),
      do: {:ok, Completion.script(shell)},
      else: {:error, "wardrik completion writes for #{Enum.join(Completion.shells(), ", ")}"}
  end

  def unanswered(["completion" | _words], _terminal),
    do: {:error, Command.usage(Enum.find(commands(), &(&1.name == "completion")))}

  def unanswered(args, _terminal) do
    case Command.find(commands(), args) do
      {:ok, _command, _rest} -> {:error, "wardrik is not running"}
      not_a_command -> {:error, unknown(not_a_command)}
    end
  end

  defp help([], terminal), do: {:ok, overview(terminal)}

  defp help(args, terminal) do
    case Command.find(commands(), args) do
      {:ok, command, _rest} -> {:ok, Command.help(command)}
      {:group, word, group} -> {:ok, group(word, group, terminal)}
      not_a_command -> {:error, unknown(not_a_command)}
    end
  end

  defp overview(terminal) do
    [
      "Usage: wardrik [--node NAME] COMMAND\n\n",
      Command.listing(commands(), terminal.width),
      "\n\n",
      first_agent(Config.config_dir()),
      about(Config.config_dir())
    ]
  end

  defp first_agent(config_dir) do
    if Path.wildcard(Path.join([config_dir, "agents", "*.md"])) == [],
      do: "No agent files yet: wardrik init sets one up.\n\n",
      else: ""
  end

  @doc """
  What `wardrik help` says after the commands it lists, for a daemon that
  reads its config from `config_dir`.
  """
  @spec about(Path.t()) :: String.t()
  def about(config_dir) do
    """
    The daemon reads config.yaml, and the agents in agents/, from
    #{config_dir}. wardrik help COMMAND says more about one.

    Where config.yaml describes a cluster, --node NAME, or WARDRIK_NODE, is which
    of its nodes a command is for. serve, start, stop, remote, logs, pid, doctor
    and service need one when this install runs several; every other command asks
    whichever node answers, since each speaks for the whole cluster.\
    """
  end

  defp group(word, commands, terminal),
    do: ["Usage: wardrik #{word} COMMAND\n\n", Command.listing(commands, terminal.width)]

  defp unknown({:ok, command, _rest}), do: "bin/wardrik runs wardrik #{command.name} itself"
  defp unknown({:group, word, commands}), do: group(word, commands, %Terminal{})
  defp unknown({:unknown, word, []}), do: ["wardrik: no command ", word]

  defp unknown({:unknown, word, nearest}),
    do: ["wardrik: no command ", word, "; did you mean ", or_list(nearest), "?"]

  # The words that can follow, a line each, and nothing where none can.
  defp complete(words, known) do
    case Completion.candidates(words, commands(), known) do
      [] -> :ok
      candidates -> IO.puts(Enum.join(candidates, "\n"))
    end
  end

  # What a running daemon knows to complete: its agents, and what each waits on.
  defp running do
    %{
      keys: fn -> Enum.map(Fleet.list(), & &1.key) end,
      calls: fn key ->
        case Agent.parked(key) do
          calls when is_list(calls) -> Enum.map(calls, &elem(&1, 0).id)
          {:error, :not_found} -> []
        end
      end
    }
  end

  defp or_list([only]), do: only

  defp or_list(names),
    do: [Enum.intersperse(Enum.drop(names, -1), ", "), " or ", List.last(names)]

  # -- the commands the daemon answers ----------------------------------------

  defp status(_words, _opts), do: {:ok, WardrikDaemon.status()}

  defp agents(_words, _opts), do: {:ok, %{"agents" => Enum.map(Fleet.list(), &Resource.agent/1)}}

  defp reload(_words, _opts) do
    for daemon <- daemons(),
        do: :erpc.call(daemon, WardrikDaemon.Agents, :reload, [], :timer.minutes(1))

    {:ok, WardrikDaemon.status()}
  end

  @doc "This node and every node connected to it that runs a daemon of its own."
  @spec daemons() :: [node()]
  def daemons do
    for daemon <- [node() | Node.list()],
        :erpc.call(daemon, Process, :whereis, [WardrikDaemon.Agents]) != nil,
        do: daemon
  end

  defp needs_terminal(_words, _opts), do: :live

  defp ask(words, opts), do: if(opts[:no_wait], do: asked(words), else: :live)

  defp asked([key | words]) do
    case Agent.ask(key, Enum.join(words, " ")) do
      :ok -> {:ok, "Asked #{key}."}
      {:error, :not_found} -> {:error, no_agent(key)}
    end
  end

  defp answer_followed([key | words], _opts, terminal) do
    if match?(%{state: :parked}, Agent.status(key)) do
      Terminal.puts(
        terminal,
        Owl.Data.tag("#{key} is waiting on a person, so this waits behind it.", @faint)
      )
    end

    case Follow.turn(key, terminal, fn -> Agent.ask(key, Enum.join(words, " ")) end) do
      {:error, :not_found} -> {:error, no_agent(key)}
      :parked -> {:ok, Owl.Data.tag("wardrik approve #{key}, or deny, decides it.", @faint)}
      :failed -> :error
      _finished_or_gone -> :ok
    end
  end

  defp watch([key], opts, terminal) do
    case {Fleet.lookup(key), opts[:json]} do
      {nil, _json?} ->
        {:error, no_agent(key)}

      {_member, true} ->
        Follow.json(key)
        :ok

      {member, _json?} ->
        Follow.events(key, terminal, watching(member))
        :ok
    end
  end

  defp watching(member) do
    Owl.Data.tag(
      "Watching #{member.key}, #{member.status} on #{Nodes.display(member.node)}. " <>
        "Ctrl-C stops watching; the agent carries on.",
      @faint
    )
  end

  defp history([key], _opts) do
    case Agent.get_context(key) do
      {:error, :not_found} -> {:error, no_agent(key)}
      context -> {:ok, conversation(context)}
    end
  end

  defp snapshot([key], _opts) do
    case Agent.snapshot(key) do
      {:error, :not_found} -> {:error, no_agent(key)}
      snapshot -> {:ok, Resource.snapshot(key, snapshot)}
    end
  end

  defp no_agent(key), do: "No agent runs under #{key}."

  defp conversation(context) do
    case ReqLLM.Context.to_list(context) do
      [] -> "Nothing has been said yet."
      messages -> Enum.map_join(messages, "\n\n", &message/1)
    end
  end

  defp message(%{role: role} = message), do: "#{role}: #{text(message)}"

  defp text(%{content: content}) when is_binary(content), do: content

  defp text(%{content: parts} = message) when is_list(parts) do
    written = for %{type: :text, text: text} <- parts, do: text

    calls =
      for call <- Map.get(message, :tool_calls) || [],
          do: "[calls #{Pattern.shown(ReqLLM.ToolCall.name(call))}]"

    Enum.join(written ++ calls, " ")
  end
end
