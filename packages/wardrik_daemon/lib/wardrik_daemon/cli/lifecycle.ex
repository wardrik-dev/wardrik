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

  `agent edit KEY` opens the file that declares the agent in `$VISUAL`, or
  `$EDITOR`, then reads the files again. `bin/wardrik` runs the editor
  itself, at the terminal the command was typed in, and asks the daemon
  where the file is with `file/1`.
  """

  alias Wardrik.AgentID
  alias Wardrik.AgentID.Prefix
  alias Wardrik.Command, as: Operation
  alias Wardrik.Fleet
  alias Wardrik.Fleet.Member
  alias Wardrik.Operations.Cancel
  alias Wardrik.Operations.CancelAgents
  alias Wardrik.Operations.Forget
  alias Wardrik.Operations.ForgetAgents
  alias Wardrik.Operations.Forgotten
  alias Wardrik.Operations.ListAgents
  alias Wardrik.Operations.Move
  alias Wardrik.Operations.ReadAgent
  alias Wardrik.Operations.Spawn
  alias Wardrik.Operations.Spawned
  alias Wardrik.Operations.SpawnOn
  alias Wardrik.Operations.Stop
  alias Wardrik.Query
  alias WardrikConsole.Nodes
  alias WardrikDaemon.CLI.Command
  alias WardrikDaemon.CLI.Terminal

  @faint [:faint, :light_black]

  @doc "The commands that start, stop and move agents, for `WardrikDaemon.CLI.commands/0`."
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
         {:ok, spawned} <- Operation.run(spawning(key, node), opts[:caller]),
         do: {:ok, spawned(spawned, key, opts[:caller])}
  end

  defp spawning(key, nil), do: %Spawn{agent: key}
  defp spawning(key, node), do: %SpawnOn{agent: key, node: node}

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

  defp spawned(%Spawned{from: :running, agent: agent}, key, _caller),
    do: "#{key} runs already, on #{on(agent)}."

  defp spawned(%Spawned{from: :store, agent: agent}, key, _caller),
    do: "Started #{key} on #{on(agent)} again, with its conversation."

  defp spawned(%Spawned{from: :definition, agent: agent}, key, _caller) do
    case WardrikDaemon.Host.declared()[key] do
      {path, _spec} -> "Started #{key} on #{on(agent)}, as #{shown(path)} declares it."
      nil -> "Started #{key} on #{on(agent)}, on the definition kept for it."
    end
  end

  defp spawned(%Spawned{from: :new, agent: agent}, key, caller) do
    {:ok, snapshot} = Query.run(%ReadAgent{agent: key}, caller)
    snapshot = ReadAgent.render(snapshot)
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
      do: cancelled(%CancelAgents{prefix: Prefix.all()}, opts[:caller]),
      else: {:error, :usage}
  end

  defp cancel([target], opts) do
    cond do
      opts[:all] -> {:error, :usage}
      prefix?(target) -> cancelled(%CancelAgents{prefix: target}, opts[:caller])
      true -> cancelled(%Cancel{agent: target}, opts[:caller])
    end
  end

  defp cancelled(request, caller) do
    with {:ok, agents} <- Operation.run(request, caller),
         do: {:ok, cancelled_line(request, agents)}
  end

  defp cancelled_line(%Cancel{agent: key}, []),
    do: "#{key} is taking no turn, so there is none to cancel."

  defp cancelled_line(%Cancel{agent: key}, [_key]),
    do:
      "Cancelled what #{key} was doing, and the messages waiting behind it. It keeps running, " <>
        "with what was said so far."

  defp cancelled_line(%CancelAgents{prefix: prefix}, []),
    do: "No agent#{under(prefix)} is taking a turn."

  defp cancelled_line(%CancelAgents{}, agents),
    do: ["Cancelled the turns of ", listed(agents), ". They keep running."]

  defp under(prefix) do
    case to_string(prefix) do
      "" -> ""
      text -> " under #{text}"
    end
  end

  defp stop([key], opts) do
    with {:ok, stopped} <- Operation.run(%Stop{agent: key}, opts[:caller]),
         do: {:ok, stopped(key, stopped)}
  end

  defp stopped(key, []),
    do: "#{key} is asleep already. It wakes when something asks it, or with #{spawn_line(key)}."

  defp stopped(key, [_key]),
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
    with {:ok, change} <- Operation.plan(forgetting(target), opts[:caller]) do
      if opts[:yes], do: removed(change, opts[:caller]), else: :live
    end
  end

  defp rm_asked([target], opts, terminal) do
    with {:ok, change} <- Operation.plan(forgetting(target), opts[:caller]) do
      preview = Operation.preview(change)

      if terminal.input?,
        do: rm_confirmed(change, preview, terminal, opts[:caller]),
        else:
          {:error,
           [
             removing(preview),
             "\nwardrik agent rm asks first only where someone can answer; ",
             "wardrik agent rm #{target} --yes removes without asking."
           ]}
    end
  end

  defp forgetting(%Prefix{} = prefix), do: %ForgetAgents{prefix: prefix}
  defp forgetting(key), do: %Forget{agent: key}

  defp rm_confirmed(change, preview, terminal, caller) do
    Terminal.puts(terminal, removing(preview))

    if Owl.IO.confirm(message: "Remove #{them(preview["forgetting"])}?", default: false),
      do: removed(change, caller),
      else: {:ok, "Nothing was removed."}
  end

  defp removing(%{"forgetting" => [key], "keeping" => kept}),
    do: ["This removes #{key}, its conversation and its triggers, for good." | left(kept)]

  defp removing(%{"forgetting" => keys, "keeping" => kept}) do
    [
      "This removes #{length(keys)} agents, their conversations and their triggers, for good:"
      | Enum.map(keys, &"\n  #{&1}")
    ] ++ left(kept)
  end

  defp left(kept), do: for(%{"why" => why} <- kept, do: ["\n", why])

  defp them([_one]), do: "it"
  defp them(_keys), do: "them"

  defp removed(change, caller) do
    with {:ok, %Forgotten{agents: gone, kept: kept, failed: failed}} <-
           Operation.make(change, caller) do
      lines =
        if(gone == [], do: [], else: ["Removed #{listed(gone)}."]) ++
          for({_key, why} <- kept, do: why) ++
          for {key, why} <- failed, do: "#{key} was not removed: #{why}"

      if failed == [], do: {:ok, Enum.join(lines, "\n")}, else: {:error, Enum.join(lines, "\n")}
    end
  end

  # -- move ---------------------------------------------------------------------

  defp move([key | named], opts) do
    with {:ok, node} <- destination(key, named, nil, opts[:caller]),
         {:ok, change} <- Operation.plan(%Move{agent: key, node: node}, opts[:caller]),
         do: moving(change, opts, nil)
  end

  defp move_asked([key | named], opts, terminal) do
    with {:ok, node} <- destination(key, named, terminal, opts[:caller]),
         {:ok, change} <- Operation.plan(%Move{agent: key, node: node}, opts[:caller]),
         do: moving(change, opts, terminal)
  end

  # Moving an agent that is doing nothing goes ahead; one taking a turn, or
  # waiting on a person, is moved only once someone agrees, or with --yes.
  defp moving(change, opts, terminal) do
    %{"moving" => %{"agent" => key, "to" => to} = moving} = Operation.preview(change)

    cond do
      moving["from"] == to -> {:ok, "#{key} runs on #{shown_node(to)} already."}
      not is_map_key(moving, "interrupting") or opts[:yes] -> moved(change, opts[:caller])
      terminal == nil -> :live
      terminal.input? -> confirmed(change, moving, terminal, opts[:caller])
      true -> {:error, "#{interrupting(moving)} #{move_line(key, to)} --yes moves it anyway."}
    end
  end

  defp confirmed(change, %{"to" => to} = moving, terminal, caller) do
    Terminal.puts(terminal, interrupting(moving))

    if Owl.IO.confirm(message: "Move it to #{shown_node(to)}?", default: false),
      do: moved(change, caller),
      else: {:ok, "Nothing was moved."}
  end

  defp move_line(key, node), do: "wardrik agent move #{key} #{shown_node(node)}"

  # The node a move is for: the one named, or one asked for where none is,
  # which needs the terminal.
  defp destination(_key, [name], _terminal, _caller), do: named_node(name)

  defp destination(_key, [], nil, _caller), do: :live

  defp destination(key, [], terminal, caller) do
    with {:ok, from} <- running_on(key, caller) do
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
  defp running_on(key, caller) do
    {:ok, members} = Query.run(%ListAgents{prefix: Prefix.of(key)}, caller)

    case Enum.find(members, &(&1.id == key)) do
      nil -> {:error, no_agent(key)}
      %Member{node: node} -> {:ok, node}
    end
  end

  defp interrupting(%{"agent" => key, "interrupting" => "turn"}),
    do: "#{key} is taking a turn, which moving it ends; what it has said so far is kept."

  defp interrupting(%{"agent" => key}),
    do: "#{key} is waiting on a person, and moving it abandons what it waits for."

  defp moved(change, caller) do
    %{"moving" => %{"agent" => key, "to" => to}} = Operation.preview(change)

    with {:ok, _answer} <- Operation.make(change, caller),
         do: {:ok, "Moved #{key} to #{shown_node(to)}, with its conversation."}
  end

  # -- edit ---------------------------------------------------------------------

  @doc """
  Where the file that declares the agent under `key` is, for `bin/wardrik` to
  open in an editor, or why there is none.
  """
  @spec file(Wardrik.AgentID.t()) :: {:ok, Path.t()} | {:error, String.t()}
  def file(key) do
    case {WardrikDaemon.Host.declared()[key], Fleet.lookup(key)} do
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

  # A node an answer names, as a person reads it.
  defp shown_node(node) when is_atom(node), do: Nodes.display(node)

  defp shown_node(name) when is_binary(name) do
    case Nodes.find(name, WardrikDaemon.daemons()) do
      nil -> name
      node -> Nodes.display(node)
    end
  end

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
