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
  it is waiting for; see `WardrikDaemon.Cluster.waiting/2`.

  A command that changes something records it in `Wardrik.Audit` once it
  has, for the account `bin/wardrik` says typed it.
  """

  alias Wardrik.Agent
  alias Wardrik.AgentID
  alias Wardrik.Error
  alias Wardrik.Fleet
  alias Wardrik.JSON
  alias Wardrik.Resource
  alias WardrikConsole.Nodes
  alias WardrikDaemon.Boot
  alias WardrikDaemon.CLI.Agents
  alias WardrikDaemon.CLI.Command
  alias WardrikDaemon.CLI.Completion
  alias WardrikDaemon.CLI.Decisions
  alias WardrikDaemon.CLI.Follow
  alias WardrikDaemon.CLI.Init
  alias WardrikDaemon.CLI.Lifecycle
  alias WardrikDaemon.CLI.Policies
  alias WardrikDaemon.CLI.Terminal
  alias WardrikDaemon.CLI.Tokens
  alias WardrikDaemon.CLI.Vault
  alias WardrikDaemon.Cluster
  alias WardrikDaemon.Config
  alias WardrikPolicy.Pattern

  @faint [:faint, :light_black]
  @audit_limit 100

  @doc """
  Every command `wardrik` takes, in the order `wardrik help` lists them: by
  group, and in a group as they are defined.
  """
  @spec commands() :: [Command.t()]
  def commands do
    Enum.sort_by(definitions(), &rank(&1.group))
  end

  # The jobs commands are listed under, in the order wardrik help lists them.
  defp rank("Set up"), do: 0
  defp rank("Talk to agents"), do: 1
  defp rank("Decide"), do: 2
  defp rank("Manage agents"), do: 3
  defp rank("Tokens and secrets"), do: 4
  defp rank("Run the daemon"), do: 5

  defp definitions do
    [
      Init.command(),
      %Command{
        name: "serve",
        group: "Run the daemon",
        summary: "run the daemon here, logging to the terminal"
      },
      %Command{
        name: "start",
        group: "Run the daemon",
        summary: "run the daemon in the background"
      },
      %Command{
        name: "stop",
        group: "Run the daemon",
        summary: "stop the daemon, and wait until it has"
      },
      %Command{
        name: "status",
        group: "Run the daemon",
        summary: "what the daemon, or its cluster, is running",
        details: ["With --json, the nodes as GET /v1/deployment/nodes lists them."],
        run: &status/2,
        json: &nodes/2
      },
      %Command{
        name: "doctor",
        group: "Set up",
        summary: "check what the daemon reads, running or not"
      },
      %Command{
        name: "reload",
        group: "Set up",
        summary: "read the agent and policy files again, for every node",
        run: &reload/2
      },
      %Command{
        name: "audit",
        group: "Run the daemon",
        options: "[--after N] [--limit N]",
        summary: "what people changed, oldest first",
        details: [
          "Up to --limit changes, #{@audit_limit} unless given, after the change numbered --after.",
          "With --json, the page as GET /v1/deployment/audit answers it."
        ],
        switches: [after: :integer, limit: :integer],
        run: &audit/2,
        json: &audit_page/2
      },
      %Command{
        name: "ask",
        group: "Talk to agents",
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
        group: "Talk to agents",
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
        group: "Talk to agents",
        arguments: "KEY",
        summary: "what an agent has said",
        details: ["With --json, the agent as GET /v1/agents/KEY answers with it."],
        count: {1, 1},
        run: &history/2,
        json: &snapshot/2
      },
      %Command{
        name: "clear",
        group: "Talk to agents",
        arguments: "KEY",
        summary: "empty an agent's conversation, and the labels of what it read",
        details: [
          "An agent whose conversation holds content from outside asks a person",
          "before each gated call until it is cleared. Its files, triggers and",
          "config stay. Refused while it runs a turn or waits on a person."
        ],
        count: {1, 1},
        run: &clear/2
      }
    ] ++
      Agents.commands() ++
      Lifecycle.commands() ++
      Decisions.commands() ++
      Policies.commands() ++ Tokens.commands() ++ Vault.commands() ++ script_commands()
  end

  # What bin/wardrik runs itself, listed for their help.
  defp script_commands do
    [
      %Command{
        name: "service install",
        group: "Run the daemon",
        summary: "run the daemon under your user's systemd"
      },
      %Command{
        name: "service uninstall",
        group: "Run the daemon",
        summary: "stop the service, and remove its unit"
      },
      %Command{
        name: "service status",
        group: "Run the daemon",
        summary: "how systemd has the service"
      },
      %Command{
        name: "service unit",
        group: "Run the daemon",
        summary: "print the unit install writes"
      },
      %Command{
        name: "attach",
        group: "Talk to agents",
        arguments: "[HOST]",
        summary: "the TUI, over SSH to HOST, localhost by default",
        count: {0, 1}
      },
      %Command{name: "remote", group: "Run the daemon", summary: "an IEx shell on the daemon"},
      %Command{name: "logs", group: "Run the daemon", summary: "follow the daemon's log"},
      %Command{name: "pid", group: "Run the daemon", summary: "the daemon's process id"},
      %Command{name: "version", group: "Run the daemon", summary: "print the version"},
      %Command{
        name: "help",
        group: "Set up",
        arguments: "[COMMAND]",
        summary: "every command, or one in full"
      },
      %Command{
        name: "completion",
        group: "Set up",
        arguments: "SHELL",
        summary: "completion for bash, zsh or fish, to install",
        count: {1, 1},
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
      Process.whereis(WardrikDaemon) ->
        ""

      reason = Cluster.refusal(Boot.cluster()) ->
        raise reason

      reason = waiting() ->
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
    case waiting() do
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
  written, and what a person types there can be read. What it logs goes to
  this node's log, as any other command's does.
  """
  @spec live([String.t()]) :: :ok
  def live(args) do
    # Logged as this node's own: logger takes an event to the node of the
    # group leader, the caller's, whose terminal would print it.
    :ok = :logger.update_process_metadata(%{gl: Process.whereis(:user)})
    {terminal, args} = Terminal.read(args)
    dispatch({%{terminal | live?: true}, args})
  end

  # What a shell completing a word asks, which nothing else may answer.
  defp dispatch({_terminal, ["__complete" | words]}), do: complete(words, running())

  # Where the file wardrik agent edit opens is, which bin/wardrik asks first.
  defp dispatch({terminal, ["__agent_file" | args]}) do
    edit = Enum.find(commands(), &(&1.name == "agent edit"))

    with {:ok, words, _opts} <- Command.parse(edit, args),
         {:ok, [key]} <- named(edit, words),
         {:ok, path} <- Lifecycle.file(key, host: WardrikDaemon.Host.get()) do
      IO.puts(path)
    else
      {:error, message} -> failed(terminal, "failed", message, false)
    end
  end

  defp dispatch({terminal, args}) do
    case waiting() do
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
      {:error, usage} ->
        failed(terminal, "invalid_request", usage, "--json" in args)

      not_a_command ->
        failed(terminal, "invalid_request", unknown(not_a_command), "--json" in args)
    end
  end

  # A KEY, first among a command's arguments, may leave out the deployment's
  # org, as Wardrik.AgentID.expand/2 reads it, and is handed on as the ID it
  # names. A PATTERN is a Wardrik.Resource pattern, as acme/agent/*, and a
  # KEY|PATTERN is a pattern where it holds * or ?, a KEY otherwise.
  defp named(%Command{arguments: arguments}, [word | rest]) do
    expanded =
      cond do
        String.starts_with?(arguments, "KEY|PATTERN") and word == "" ->
          {:error, "Name an agent's key, or a pattern such as 'acme/agent/*'."}

        String.starts_with?(arguments, "KEY|PATTERN") and String.contains?(word, ["*", "?"]) ->
          Resource.parse(word)

        String.starts_with?(arguments, ["KEY", "[KEY"]) ->
          AgentID.expand(word, Config.org(WardrikDaemon.Host.config()))

        String.starts_with?(arguments, "[PATTERN") ->
          Resource.parse(word)

        true ->
          {:ok, word}
      end

    with {:ok, word} <- expanded, do: {:ok, [word | rest]}
  end

  defp named(_command, []), do: {:ok, []}

  defp answer(terminal, %Command{} = command, words, opts) do
    json? = Keyword.get(opts, :json, false) and command.json != nil
    by = Terminal.principal(terminal)
    host = WardrikDaemon.Host.get()

    opts =
      Keyword.merge(opts,
        by: by,
        as: Wardrik.as(host, by),
        config: WardrikDaemon.Host.config()
      )

    command
    |> respond(words, opts, terminal, json?)
    |> answered(terminal, command, json?)
  end

  defp answered({:ok, document}, _terminal, _command, true),
    do: IO.puts(Elixir.JSON.encode!(document))

  defp answered({:ok, text}, terminal, _command, false), do: Terminal.puts(terminal, text)
  defp answered(:ok, _terminal, _command, _json?), do: :ok
  defp answered(:live, _terminal, _command, _json?), do: exit({:shutdown, :live})
  defp answered(:error, _terminal, _command, _json?), do: exit({:shutdown, 1})

  defp answered({:error, :usage}, terminal, command, json?),
    do: failed(terminal, "invalid_request", Command.usage(command), json?)

  defp answered({:error, %Error{} = error}, terminal, _command, json?),
    do: failed(terminal, error, json?)

  defp answered({:error, message}, terminal, _command, json?),
    do: failed(terminal, "failed", message, json?)

  defp respond(%Command{json: json}, words, opts, _terminal, true), do: json.(words, opts)

  defp respond(%Command{run: run, live: live}, words, opts, terminal, false) do
    case run.(words, opts) do
      :live when terminal.live? -> live.(words, opts, terminal)
      answer -> answer
    end
  end

  # A command that fails prints why, or with --json an error of `type`
  # saying so, as the HTTP API answers it, and exits with status 1.
  defp failed(terminal, %Error{message: message} = error, json?) do
    if json?,
      do: IO.puts(Elixir.JSON.encode!(JSON.error(error))),
      else: Terminal.puts(terminal, message)

    exit({:shutdown, 1})
  end

  defp failed(terminal, type, message, json?) do
    if json?,
      do: IO.puts(Elixir.JSON.encode!(JSON.error(type, plain(message)))),
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
    complete(words, %{keys: fn -> [] end, calls: fn _key -> [] end, nodes: fn -> [] end})
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
      Command.grouped(commands(), terminal.width),
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
    rik is a short name for wardrik: rik ls is wardrik ls.

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

  # What a running daemon knows to complete: its agents, what each waits on,
  # and the nodes an agent can move to.
  defp running do
    host = WardrikDaemon.Host.get()

    %{
      keys: fn -> Enum.map(Fleet.list(Resource.parse!("*"), host: host), &to_string(&1.id)) end,
      nodes: fn -> Enum.map(WardrikDaemon.daemons(), &Nodes.display/1) end,
      calls: fn key ->
        case Agent.parked(key, host: host) do
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

  # Asked of what the release booted with, held before the daemon's tree
  # reads config.yaml, so a node waiting for its cluster can say how many it
  # waits for.
  defp waiting, do: Cluster.waiting(Boot.cluster(), Boot.store())

  defp status(_words, opts), do: {:ok, WardrikDaemon.status(opts[:as].host, opts[:config])}

  defp nodes(_words, opts) do
    with {:ok, nodes} <- Wardrik.deployment_nodes(opts[:as]),
         do: {:ok, JSON.nodes(nodes)}
  end

  defp reload(_words, opts) do
    with {:ok, _reloaded} <- Wardrik.deployment_reload(opts[:as]),
         do: {:ok, WardrikDaemon.status(opts[:as].host, opts[:config])}
  end

  defp audit_page(_words, opts) do
    limit = opts[:limit] || @audit_limit

    if limit in 1..500,
      do:
        with(
          {:ok, read} <-
            Wardrik.deployment_audit(opts[:as], after: opts[:after] || 0, limit: limit),
          do: {:ok, %{"changes" => Enum.map(read, & &1.cloudevent)}}
        ),
      else: {:error, "--limit is a number from 1 to 500"}
  end

  defp audit(words, opts) do
    with {:ok, %{"changes" => changes}} <- audit_page(words, opts) do
      {:ok, changes(changes, opts[:after] || 0, opts[:limit] || @audit_limit)}
    end
  end

  defp changes([], starting_after, _limit), do: "No changes after #{starting_after}."

  defp changes(changes, _starting_after, limit) do
    lines = Enum.map(changes, &change/1)
    last = String.to_integer(List.last(changes)["sequence"])

    if length(changes) == limit,
      do: Enum.join(lines ++ ["More: wardrik audit --after #{last}"], "\n"),
      else: Enum.join(lines, "\n")
  end

  defp change(%{"sequence" => sequence, "type" => "wardrik." <> type} = change) do
    {:ok, at, _offset} = DateTime.from_iso8601(change["time"])

    Enum.join(
      [
        String.to_integer(sequence),
        at |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
        type,
        change["subject"],
        by(change["data"]["actor"])
      ],
      "  "
    )
  end

  defp by(nil), do: "by nobody known"
  defp by(%{"id" => id}), do: "by " <> id

  defp needs_terminal(_words, _opts), do: :live

  defp ask(words, opts), do: if(opts[:no_wait], do: asked(words, opts), else: :live)

  defp asked([key | words], opts) do
    with {:ok, _message} <- asking(key, words, opts[:as]), do: {:ok, "Asked #{key}."}
  end

  defp asking(key, words, scope), do: Wardrik.agent_ask(scope, key, Enum.join(words, " "))

  defp answer_followed([key | words], opts, terminal) do
    if match?(%{state: :parked}, Agent.status(key, host: opts[:as].host)) do
      Terminal.puts(
        terminal,
        Owl.Data.tag("#{key} is waiting on a person, so this waits behind it.", @faint)
      )
    end

    case Follow.turn(key, terminal, fn -> sent(asking(key, words, opts[:as])) end) do
      {:error, %Error{} = error} -> {:error, error}
      :parked -> {:ok, Owl.Data.tag("wardrik approve #{key}, or deny, decides it.", @faint)}
      :failed -> :error
      _finished_or_gone -> :ok
    end
  end

  defp sent({:ok, _answer}), do: :ok
  defp sent({:error, error}), do: {:error, error}

  defp watch([key], opts, terminal) do
    case {Fleet.lookup(key, host: opts[:as].host), opts[:json]} do
      {nil, _json?} ->
        {:error, no_agent(key)}

      {_member, true} ->
        Follow.json(opts[:as], key)
        :ok

      {member, _json?} ->
        Follow.events(key, terminal, watching(member))
        :ok
    end
  end

  defp watching(%{asleep: true} = member) do
    Owl.Data.tag(
      "Watching #{member.id}, #{Wardrik.Fleet.Member.label(member)} until something asks it. " <>
        "Ctrl-C stops watching.",
      @faint
    )
  end

  defp watching(member) do
    Owl.Data.tag(
      "Watching #{member.id}, #{Wardrik.Fleet.Member.label(member)} on #{Nodes.display(member.node)}. " <>
        "Ctrl-C stops watching; the agent carries on.",
      @faint
    )
  end

  defp history([key], opts) do
    with {:ok, snapshot} <- snapshot([key], opts), do: {:ok, conversation(snapshot["messages"])}
  end

  defp snapshot([key], opts) do
    with {:ok, snapshot} <- Wardrik.agent_read(opts[:as], key),
         do: {:ok, JSON.snapshot(snapshot)}
  end

  defp clear([key], opts) do
    with {:ok, _snapshot} <- Wardrik.agent_clear(opts[:as], key),
         do: {:ok, "Cleared #{key}'s conversation."}
  end

  defp no_agent(key), do: "No agent runs under #{key}."

  defp conversation([]), do: "Nothing has been said yet."
  defp conversation(messages), do: Enum.map_join(messages, "\n\n", &message/1)

  defp message(%{"role" => role, "parts" => parts}),
    do: "#{role}: #{Enum.map_join(parts, " ", &part/1)}"

  defp part(%{"type" => "text", "content" => text}), do: text
  defp part(%{"type" => "tool_call", "name" => name}), do: "[calls #{Pattern.shown(name)}]"
  defp part(%{"type" => "tool_call_response", "response" => response}), do: to_string(response)
  defp part(_other), do: ""
end
