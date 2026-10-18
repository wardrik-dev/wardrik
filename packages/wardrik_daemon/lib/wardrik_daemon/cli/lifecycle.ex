defmodule WardrikDaemon.CLI.Lifecycle do
  @moduledoc """
  `wardrik agent`: starting, cancelling, stopping, removing, moving and
  editing agents.

  `agent spawn NAME` starts the agent `agents/NAME.md` declares, writing the
  file from `config.yaml`'s `defaults` first where there is none, and reads
  the files again on every node, as `wardrik reload` does. `--org` and
  `--user` put the agent in an org, or with one of its users, as a file's
  `org` and `user` do, and `--on NODE` starts it on that node. An agent
  `agent stop` stopped comes back as it was, and one no file declares is
  given no file.

  `agent cancel` ends the turn an agent is taking, or abandons the one it
  waits on a person for, with the messages waiting behind it, for one agent,
  every agent under a prefix, or with `--all` every agent there is; the
  agents keep running. `agent stop` stops one and keeps its conversation. An agent a
  file declares starts again at the next `wardrik reload`.

  `agent rm` removes an agent, running or stopped, or every agent running
  under a prefix, with its conversation and triggers, for good. It lists
  what it removes and asks first; `--yes` removes without asking, as it must
  where nobody can answer. It leaves an agent a file declares: removing the
  file, then `wardrik reload`, removes that one.

  `agent move KEY NODE` restarts an agent on another node, with its
  conversation, and asks which node where none is named. Moving an agent
  ends a turn it is taking, and abandons what it waits on a person for, so
  `move` asks first; `--yes` moves it without asking.

  `agent calls KEY` lists the tool calls an agent is running, and
  `agent kill-call KEY CALL_ID` stops one: the model is answered with an
  error, and the rest of the turn goes on.

  `agent edit KEY` opens the file that declares the agent in `$VISUAL`, or
  `$EDITOR`, then reads the files again. `bin/wardrik` runs the editor
  itself, at the terminal the command was typed in, and asks the daemon
  where the file is with `file/1`.
  """

  alias Wardrik.AgentID
  alias Wardrik.AgentID.Prefix
  alias Wardrik.Fleet
  alias Wardrik.Fleet.Member
  alias Wardrik.Forgetting
  alias Wardrik.Moving
  alias Wardrik.Spawned
  alias WardrikConsole.Nodes
  alias WardrikDaemon.CLI.Command
  alias WardrikDaemon.CLI.Terminal

  @faint [:faint, :light_black]

  @doc """
  The commands that start, stop and move agents, and stop their tool calls,
  for `WardrikDaemon.CLI.commands/0`.
  """
  @spec commands() :: [Command.t()]
  def commands do
    [
      %Command{
        name: "agent spawn",
        group: "Manage agents",
        arguments: "NAME",
        options: "[--org ORG] [--user USER] [--on NODE]",
        summary: "start an agent, writing its file from config.yaml's defaults if it has none",
        details: [
          "It starts the agent agents/NAME.md declares, writing the file first where there",
          "is none, and reads the files again, as wardrik reload does. --org and --user put",
          "it in an org, or with one of its users, and --on NODE starts it on that node. An",
          "agent wardrik agent stop stopped comes back with its conversation."
        ],
        switches: [org: :string, user: :string, on: :string],
        count: {1, 1},
        run: &spawn_agent/2
      },
      %Command{
        name: "agent cancel",
        group: "Manage agents",
        arguments: "KEY|PREFIX/",
        options: "[--all]",
        summary: "end the turn an agent is taking; it keeps running",
        details: [
          "The messages waiting behind the turn go too, and a turn waiting on a person is",
          "abandoned. A PREFIX/, such as acme/, ends the turns of every agent under it, and",
          "--all those of every agent there is."
        ],
        switches: [all: :boolean],
        count: {0, 1},
        run: &cancel/2
      },
      %Command{
        name: "agent stop",
        group: "Manage agents",
        arguments: "KEY",
        summary: "stop an agent now, keeping its conversation; it wakes when asked again",
        details: [
          "Anything asked of it by its key wakes it, as does wardrik agent spawn. wardrik agent " <>
            "rm removes it for good once no file declares it."
        ],
        count: {1, 1},
        run: &stop/2
      },
      %Command{
        name: "agent rm",
        group: "Manage agents",
        arguments: "KEY|PREFIX/",
        options: "[--yes]",
        summary: "remove an agent, its conversation and its triggers, for good",
        details: [
          "It lists what it removes and asks first; --yes removes without asking. A PREFIX/,",
          "such as acme/, removes every agent under it. An agent a file declares is left:",
          "remove the file, then wardrik reload removes it."
        ],
        switches: [yes: :boolean],
        count: {1, 1},
        run: &rm/2,
        live: &rm_asked/3
      },
      %Command{
        name: "agent move",
        group: "Manage agents",
        arguments: "KEY [NODE]",
        options: "[--yes]",
        summary: "restart an agent on another node, with its conversation",
        details: [
          "Without NODE it asks which. Moving ends a turn the agent is taking, and abandons",
          "what it waits on a person for, so it asks first; --yes moves it without asking."
        ],
        switches: [yes: :boolean],
        count: {1, 2},
        run: &move/2,
        live: &move_asked/3
      },
      %Command{
        name: "agent calls",
        group: "Manage agents",
        arguments: "KEY",
        summary: "the tool calls an agent is running, and how long each has run",
        details: ["With --json, the calls as GET /v1/agents/KEY/calls answers them."],
        count: {1, 1},
        run: &calls/2,
        json: &calls_json/2
      },
      %Command{
        name: "agent kill-call",
        group: "Manage agents",
        arguments: "KEY CALL_ID",
        summary: "stop one tool call an agent is running; the rest of its turn goes on",
        details: [
          "The model is answered with an error, as if the tool had failed. wardrik agent",
          "calls lists the calls; wardrik agent cancel ends the whole turn instead."
        ],
        count: {2, 2},
        run: &kill_call/2
      },
      %Command{
        name: "agent edit",
        group: "Manage agents",
        arguments: "KEY",
        summary: "edit the file that declares an agent, then read the files again",
        details: ["It opens the file in $VISUAL, or $EDITOR, or vi."],
        count: {1, 1}
      }
    ]
  end

  # -- spawn --------------------------------------------------------------------

  defp spawn_agent([name], opts) do
    with {:ok, key} <- key(name, opts),
         {:ok, node} <- named_node(opts[:on]),
         {:ok, %Spawned{member: agent, from: from}} <-
           Wardrik.agent_spawn(opts[:session], key, if(node, do: [node: node], else: [])),
         do: {:ok, spawned(from, agent, key, opts[:session])}
  end

  defp key(name, opts) do
    named = [
      {name, "#{name} is not an agent's name"},
      {opts[:org], "--org #{opts[:org]} is not an org's name"},
      {opts[:user], "--user #{opts[:user]} is not a user's name"}
    ]

    config = WardrikDaemon.Host.config()

    case Enum.find(named, fn {text, _message} ->
           text != nil and not AgentID.segment?(text)
         end) do
      nil ->
        org = opts[:org] || WardrikDaemon.Config.org(config)

        with :ok <- WardrikDaemon.Config.declared(config, org),
             do: {:ok, AgentID.new!(name, org: org, user: opts[:user])}

      {_text, message} ->
        {:error, message <> ": a name holds no / or whitespace, and does not begin with @ or _"}
    end
  end

  defp spawned(:running, agent, key, _session),
    do: "#{key} runs already, on #{on(agent)}."

  defp spawned(:store, agent, key, _session),
    do: "Started #{key} on #{on(agent)} again, with its conversation."

  defp spawned(:definition, agent, key, _session) do
    case WardrikDaemon.Host.declared()[key] do
      {path, _spec} -> "Started #{key} on #{on(agent)}, as #{shown(path)} declares it."
      nil -> "Started #{key} on #{on(agent)}, on the definition kept for it."
    end
  end

  defp spawned(:new, agent, key, session) do
    {:ok, snapshot} = Wardrik.agent_read(session, key)
    snapshot = Wardrik.Resource.snapshot(snapshot)
    {path, _spec} = WardrikDaemon.Host.declared()[key]

    [
      "Wrote #{shown(path)}, and started #{key} on #{on(agent)}, ",
      "with #{model(snapshot)}.\n",
      Owl.Data.tag("wardrik agent edit #{key} changes what it is for.", @faint)
    ]
  end

  defp on(%Member{node: node}), do: shown_node(node)

  defp model(%{"provider" => %{"name" => provider}, "request" => %{"model" => model}}),
    do: "#{provider}:#{model}"

  defp model(%{"request" => %{"model" => model}}), do: model

  # -- cancel and stop ------------------------------------------------------------

  defp cancel([], opts) do
    if opts[:all],
      do: cancelled_under(Prefix.all(), opts[:session]),
      else: {:error, :usage}
  end

  defp cancel([target], opts) do
    cond do
      opts[:all] -> {:error, :usage}
      prefix?(target) -> cancelled_under(target, opts[:session])
      true -> cancelled(target, opts[:session])
    end
  end

  defp cancelled(key, session) do
    busy? = match?(%Member{status: status} when status != :idle, member(key, session))
    with :ok <- Wardrik.agent_cancel(session, key), do: {:ok, cancelled_line(key, busy?)}
  end

  defp cancelled_under(prefix, session) do
    with {:ok, agents} <- Wardrik.agents_cancel(session, prefix),
         do: {:ok, cancelled_under_line(prefix, agents)}
  end

  defp cancelled_line(key, false), do: "#{key} is taking no turn, so there is none to cancel."

  defp cancelled_line(key, true),
    do:
      "Cancelled what #{key} was doing, and the messages waiting behind it. It keeps running, " <>
        "with what was said so far."

  defp cancelled_under_line(prefix, []), do: "No agent#{under(prefix)} is taking a turn."

  defp cancelled_under_line(_prefix, agents),
    do: ["Cancelled the turns of ", listed(agents), ". They keep running."]

  defp under(prefix) do
    case to_string(prefix) do
      "" -> ""
      text -> " under #{text}"
    end
  end

  defp stop([key], opts) do
    asleep? = match?(%Member{asleep: true}, member(key, opts[:session]))

    with {:ok, _member} <- Wardrik.agent_stop(opts[:session], key),
         do: {:ok, stopped(key, asleep?)}
  end

  # The agent `key` as the fleet lists it, read before a stop or a cancel,
  # which answer only that they were made, so the line can say what each
  # found.
  defp member(key, session) do
    {:ok, members} = Wardrik.agents_list(session, Prefix.of(key))
    Enum.find(members, &(&1.id == key))
  end

  defp stopped(key, true),
    do: "#{key} is asleep already. It wakes when something asks it, or with #{spawn_line(key)}."

  defp stopped(key, false),
    do:
      "Stopped #{key}, and kept its conversation. It wakes when something asks it, or with " <>
        "#{spawn_line(key)}."

  defp spawn_line(%AgentID{org: org, user: user, name: name}) do
    Enum.join(
      ["wardrik agent spawn", name] ++
        if(org != WardrikDaemon.Config.org(WardrikDaemon.Host.config()),
          do: ["--org", org],
          else: []
        ) ++
        if(user, do: ["--user", user], else: []),
      " "
    )
  end

  # -- rm -----------------------------------------------------------------------

  defp rm([target], opts) do
    with {:ok, _forgetting} <- forgetting(target, opts[:session]) do
      if opts[:yes], do: removed(target, opts[:session]), else: :live
    end
  end

  defp rm_asked([target], opts, terminal) do
    with {:ok, forgetting} <- forgetting(target, opts[:session]) do
      if terminal.input?,
        do: rm_confirmed(target, forgetting, terminal, opts[:session]),
        else:
          {:error,
           [
             removing(forgetting),
             "\nwardrik agent rm asks first only where someone can answer; ",
             "wardrik agent rm #{target} --yes removes without asking."
           ]}
    end
  end

  defp forgetting(%AgentID{} = key, session), do: Wardrik.agent_forget_preview(session, key)
  defp forgetting(prefix, session), do: Wardrik.agents_forget_preview(session, prefix)

  defp rm_confirmed(target, forgetting, terminal, session) do
    Terminal.puts(terminal, removing(forgetting))

    if Owl.IO.confirm(message: "Remove #{them(forgetting.agents)}?", default: false),
      do: removed(target, session),
      else: {:ok, "Nothing was removed."}
  end

  defp removing(%Forgetting{agents: [key], kept: kept}),
    do: ["This removes #{key}, its conversation and its triggers, for good." | left(kept)]

  defp removing(%Forgetting{agents: keys, kept: kept}) do
    [
      "This removes #{length(keys)} agents, their conversations and their triggers, for good:"
      | Enum.map(keys, &"\n  #{&1}")
    ] ++ left(kept)
  end

  defp left(kept), do: for({_key, why} <- kept, do: ["\n", why])

  defp them([_one]), do: "it"
  defp them(_keys), do: "them"

  # An agent is removed on its own, answered with what became of it as one
  # under a prefix is.
  defp forget(%AgentID{} = key, session) do
    with :ok <- Wardrik.agent_forget(session, key), do: {:ok, %{key => :forgotten}}
  end

  defp forget(prefix, session), do: Wardrik.agents_forget(session, prefix)

  defp removed(target, session) do
    with {:ok, outcomes} <- forget(target, session) do
      outcomes = Enum.sort_by(outcomes, fn {key, _outcome} -> to_string(key) end)
      gone = for {key, :forgotten} <- outcomes, do: key
      failed = for {key, {:failed, why}} <- outcomes, do: "#{key} was not removed: #{why}"

      lines =
        if(gone == [], do: [], else: ["Removed #{listed(gone)}."]) ++
          for({_key, {:kept, why}} <- outcomes, do: why) ++ failed

      if failed == [], do: {:ok, Enum.join(lines, "\n")}, else: {:error, Enum.join(lines, "\n")}
    end
  end

  # -- move ---------------------------------------------------------------------

  defp move([key | named], opts) do
    with {:ok, node} <- destination(key, named, nil, opts[:session]),
         {:ok, moving} <- Wardrik.agent_move_preview(opts[:session], key, node),
         do: moving(moving, opts, nil)
  end

  defp move_asked([key | named], opts, terminal) do
    with {:ok, node} <- destination(key, named, terminal, opts[:session]),
         {:ok, moving} <- Wardrik.agent_move_preview(opts[:session], key, node),
         do: moving(moving, opts, terminal)
  end

  # Moving an agent that is doing nothing goes ahead; one taking a turn, or
  # waiting on a person, is moved only once someone agrees, or with --yes.
  defp moving(%Moving{agent: key, from: to, to: to}, _opts, _terminal),
    do: {:ok, "#{key} runs on #{shown_node(to)} already."}

  defp moving(%Moving{agent: key, to: to} = moving, opts, terminal) do
    cond do
      moving.status == :idle or opts[:yes] -> moved(moving, opts[:session])
      terminal == nil -> :live
      terminal.input? -> confirmed(moving, terminal, opts[:session])
      true -> {:error, "#{interrupting(moving)} #{move_line(key, to)} --yes moves it anyway."}
    end
  end

  defp confirmed(%Moving{to: to} = moving, terminal, session) do
    Terminal.puts(terminal, interrupting(moving))

    if Owl.IO.confirm(message: "Move it to #{shown_node(to)}?", default: false),
      do: moved(moving, session),
      else: {:ok, "Nothing was moved."}
  end

  defp move_line(key, node), do: "wardrik agent move #{key} #{shown_node(node)}"

  # The node a move is for: the one named, or one asked for where none is,
  # which needs the terminal.
  defp destination(_key, [name], _terminal, _session), do: named_node(name)

  defp destination(_key, [], nil, _session), do: :live

  defp destination(key, [], terminal, session) do
    with {:ok, from} <- running_on(key, session) do
      case Enum.reject(WardrikDaemon.daemons(), &(&1 == from)) do
        [] ->
          {:error, "#{shown_node(from)} is the only node, so there is nowhere to move #{key} to."}

        others when terminal.input? ->
          {:ok,
           Owl.IO.select(others,
             label: "Move #{key} from #{shown_node(from)} to which node?",
             render_as: &Nodes.display/1
           )}

        others ->
          {:error,
           "wardrik agent move asks which node only where someone can answer; name it, as in " <>
             "#{move_line(key, hd(others))}. The nodes are #{nodes(others)}."}
      end
    end
  end

  # The node the agent `key` runs on, as the fleet lists it.
  defp running_on(key, session) do
    case member(key, session) do
      nil -> {:error, no_agent(key)}
      %Member{node: node} -> {:ok, node}
    end
  end

  defp interrupting(%Moving{agent: key, status: :running}),
    do: "#{key} is taking a turn, which moving it ends; what it has said so far is kept."

  defp interrupting(%Moving{agent: key}),
    do: "#{key} is waiting on a person, and moving it abandons what it waits for."

  defp moved(%Moving{agent: key, to: to}, session) do
    with {:ok, _member} <- Wardrik.agent_move(session, key, to),
         do: {:ok, "Moved #{key} to #{shown_node(to)}, with its conversation."}
  end

  # -- tool calls ---------------------------------------------------------------

  defp calls([key], opts) do
    with {:ok, calls} <- Wardrik.agent_calls(opts[:session], key), do: {:ok, running(key, calls)}
  end

  defp running(key, []), do: "#{key} is running no tool call."

  defp running(key, calls) do
    rows =
      for call <- calls,
          do: "  #{call.call_id}  #{call.name}  #{WardrikDaemon.duration(call.elapsed_ms)}"

    Enum.join(["#{key} is running:" | rows], "\n")
  end

  defp calls_json([key], opts) do
    with {:ok, calls} <- Wardrik.agent_calls(opts[:session], key),
         do: {:ok, Wardrik.Resource.calls(calls)}
  end

  defp kill_call([key, call_id], opts) do
    with :ok <- Wardrik.agent_call_kill(opts[:session], key, call_id),
         do: {:ok, "Stopped #{call_id}. #{key} is told it failed, and its turn goes on."}
  end

  # -- edit ---------------------------------------------------------------------

  @doc """
  Where the file that declares the agent under `key` is, for `bin/wardrik` to
  open in an editor, or why there is none, asking the definitions of the
  `:host` given for one no file declares.
  """
  @spec file(Wardrik.AgentID.t(), host: Wardrik.Host.t()) ::
          {:ok, Path.t()} | {:error, String.t()}
  def file(key, opts) do
    case {WardrikDaemon.Host.declared()[key], Fleet.lookup(key, opts)} do
      {{path, _spec}, _member} ->
        {:ok, path}

      {nil, nil} ->
        {:error, no_agent(key)}

      {nil, _member} ->
        {:error,
         "No file declares #{key}: it was defined over the HTTP API, or started in the TUI, " <>
           "so there is none to edit."}
    end
  end

  # -- shared -------------------------------------------------------------------

  # A node running a daemon, by any name Nodes.find/2 reads.
  defp named_node(nil), do: {:ok, nil}

  defp named_node(name) do
    daemons = WardrikDaemon.daemons()

    case Nodes.find(name, daemons) do
      nil -> {:error, "No node #{name} runs wardrik; the nodes are #{nodes(daemons)}."}
      node -> {:ok, node}
    end
  end

  defp nodes(daemons), do: daemons |> Enum.map(&Nodes.display/1) |> listed()

  # A node, as a person reads it.
  defp shown_node(node), do: Nodes.display(node)

  defp prefix?(target), do: match?(%Prefix{}, target)

  defp shown(path), do: Path.join("agents", Path.basename(path))

  defp no_agent(key), do: "No agent runs under #{key}."

  defp listed(items) do
    case Enum.map(items, &to_string/1) do
      [only] -> only
      texts -> [Enum.intersperse(Enum.drop(texts, -1), ", "), " and ", List.last(texts)]
    end
  end
end
