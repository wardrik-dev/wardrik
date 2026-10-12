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
  under a prefix, with its conversation and schedules, for good. It lists
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

  alias Wardrik.Agent
  alias Wardrik.Agent.Spec
  alias Wardrik.AgentID
  alias Wardrik.AgentID.Prefix
  alias Wardrik.Audit
  alias Wardrik.Event.Codec.Value
  alias Wardrik.Fleet
  alias WardrikConsole.Nodes
  alias WardrikDaemon.AgentFile
  alias WardrikDaemon.Agents
  alias WardrikDaemon.CLI
  alias WardrikDaemon.CLI.Command
  alias WardrikDaemon.CLI.Terminal

  @faint [:faint, :light_black]

  # The order a file spawn writes gives config.yaml's defaults.
  @defaults ~w(model tools policy timeout max_iterations compaction)

  @doc "The commands that start, stop and move agents, for `WardrikDaemon.CLI.commands/0`."
  @spec commands() :: [Command.t()]
  def commands do
    [
      %Command{
        name: "agent spawn",
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
        arguments: "KEY",
        summary: "stop an agent, and keep its conversation for agent spawn",
        details: ["An agent a file declares starts again at the next wardrik reload."],
        count: {1, 1},
        run: &stop/2
      },
      %Command{
        name: "agent rm",
        arguments: "KEY|PREFIX/",
        options: "[--yes]",
        summary: "remove an agent, its conversation and its schedules, for good",
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
         {:ok, node} <- named_node(opts[:on]) do
      path = Path.join([Agents.dir(), "agents", name <> ".md"])

      cond do
        member = awake(key) ->
          {:ok, "#{key} runs already, on #{Nodes.display(member.node)}."}

        file = WardrikDaemon.declared()[key] ->
          restart(file, node, opts[:by])

        Fleet.stored?(key) ->
          resume(key, node, opts[:by])

        File.exists?(path) ->
          taken(path)

        true ->
          write(key, path, opts, node)
      end
    end
  end

  defp key(name, opts) do
    named = [
      {name, "#{name} is not an agent's name"},
      {opts[:org], "--org #{opts[:org]} is not an org's name"},
      {opts[:user], "--user #{opts[:user]} is not a user's name"}
    ]

    case Enum.find(named, fn {text, _message} ->
           text != nil and not AgentID.segment?(text)
         end) do
      nil ->
        {:ok,
         AgentID.new!(name, org: opts[:org] || WardrikDaemon.Config.org(), user: opts[:user])}

      {_text, message} ->
        {:error, message <> ": a name holds no / or whitespace, and does not begin with @ or _"}
    end
  end

  defp restart({path, spec}, node, by) do
    key = spec.id

    with :ok <- placed(key, Spec.options(spec), node) do
      case Fleet.put(spec) do
        {:ok, pid} ->
          on = node(pid)
          :ok = Audit.record({:agent_spawned, key, on}, by)
          {:ok, "Started #{key} on #{Nodes.display(on)}, as #{shown(path)} declares it."}

        {:error, reason} ->
          {:error, "#{key} did not start: #{inspect(reason)}"}
      end
    end
  end

  # An agent stopped with no file declaring it starts from what it had.
  defp resume(key, node, by) do
    case Fleet.spawn(key, if(node, do: [node: node], else: [])) do
      {:ok, pid} ->
        on = node(pid)
        :ok = Audit.record({:agent_spawned, key, on}, by)
        {:ok, "Started #{key} on #{Nodes.display(on)} again, with its conversation."}

      {:error, reason} ->
        {:error, not_started(key, reason, node)}
    end
  end

  defp taken(path) do
    case Enum.find(WardrikDaemon.declared(), fn {_key, {file, _spec}} -> file == path end) do
      {other, _file} ->
        {:error, "#{shown(path)} is there already, and declares #{other}."}

      nil ->
        {:error,
         "#{shown(path)} is there already, and is kept as it is: wardrik reload reads it, " <>
           "and wardrik status says why where it does not."}
    end
  end

  # The file is written only once the defaults are known to make an agent
  # under the key, and never over one that is there.
  defp write(key, path, opts, node) do
    with {:ok, options} <- defaults(key),
         :ok <- create(path, AgentFile.text(fields(opts))),
         :ok <- placed(key, options, node) do
      _reloaded = CLI.reload_all()
      written(key, path, opts[:by])
    end
  end

  defp create(path, text) do
    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, text, [:exclusive]) do
      :ok
    else
      {:error, reason} ->
        {:error, "#{shown(path)} could not be written: #{:file.format_error(reason)}"}
    end
  end

  defp defaults(key) do
    case Agents.options(key) do
      {:ok, options} ->
        {:ok, options}

      {:error, message} ->
        {:error, "config.yaml's defaults do not make an agent for #{key}: #{message}"}
    end
  end

  defp fields(opts) do
    defaults = Agents.defaults()

    for({key, value} <- [{"org", opts[:org]}, {"user", opts[:user]}], value, do: {key, value}) ++
      for key <- @defaults, Map.has_key?(defaults, key), do: {key, defaults[key]}
  end

  defp written(key, path, by) do
    case List.keyfind(Agents.files(), path, 0) do
      {^path, {:ok, spec}} ->
        on = running_on(key)
        :ok = Audit.record({:agent_spawned, key, on}, by)

        {:ok,
         [
           "Wrote #{shown(path)}, and started #{key} on #{Nodes.display(on)}, ",
           "with #{model(spec)}.\n",
           Owl.Data.tag("wardrik agent edit #{key} changes what it is for.", @faint)
         ]}

      {^path, {:error, message}} ->
        {:error, message}
    end
  end

  defp running_on(key) do
    case awake(key) do
      nil -> node()
      member -> member.node
    end
  end

  # A sleeping agent runs nowhere; spawning it wakes it.
  defp awake(key) do
    case Fleet.lookup(key) do
      %{asleep: false} = member -> member
      _asleep_or_none -> nil
    end
  end

  defp model(spec) do
    case Value.model(spec.config.model_spec) do
      {nil, model} -> model
      {provider, model} -> "#{provider}:#{model}"
    end
  end

  # An agent bound for a node is started there first; reading the files then
  # finds it running.
  defp placed(_key, _options, nil), do: :ok

  defp placed(key, options, node) do
    case Fleet.spawn(key, options ++ [node: node]) do
      {:ok, _pid} -> :ok
      {:error, reason} -> {:error, not_started(key, reason, node)}
    end
  end

  defp not_started(key, {:erpc, reason}, node),
    do: "#{key} did not start: #{Nodes.display(node)} could not be reached (#{inspect(reason)})"

  defp not_started(key, reason, _node), do: "#{key} did not start: #{inspect(reason)}"

  # -- cancel and stop ------------------------------------------------------------

  defp cancel([], opts),
    do: if(opts[:all], do: cancel_under(Prefix.all(), opts[:by]), else: {:error, :usage})

  defp cancel([target], opts) do
    cond do
      opts[:all] -> {:error, :usage}
      prefix?(target) -> cancel_under(target, opts[:by])
      true -> cancel_one(target, opts[:by])
    end
  end

  defp cancel_one(key, by) do
    with %{status: status} when status != :idle <- Fleet.lookup(key),
         :ok <- Agent.interrupt(key) do
      :ok = Audit.record({:agent_cancelled, key}, by)
      {:ok, cancelled(key, status)}
    else
      %{status: :idle} -> {:ok, "#{key} is taking no turn, so there is none to cancel."}
      _gone -> {:error, no_agent(key)}
    end
  end

  defp cancelled(key, :parked),
    do:
      "Abandoned the calls #{key} waited on, and the messages waiting behind them. It keeps " <>
        "running, with what was said so far."

  defp cancelled(key, _running),
    do:
      "Cancelled #{key}'s turn, and the messages waiting behind it. It keeps running, " <>
        "with what was said so far."

  defp cancel_under(prefix, by) do
    busy = for %{status: status, id: key} <- Fleet.list(prefix), status != :idle, do: key

    case {Fleet.kill(prefix), busy} do
      {0, _busy} ->
        {:ok, "Nothing runs#{under(prefix)}."}

      {_count, []} ->
        {:ok, "No agent#{under(prefix)} is taking a turn."}

      {count, busy} ->
        :ok = Audit.record({:agents_cancelled, prefix, count}, by)
        {:ok, "Cancelled the turns of #{listed(busy)}. They keep running."}
    end
  end

  defp under(prefix) do
    case to_string(prefix) do
      "" -> ""
      text -> " under #{text}"
    end
  end

  defp stop([key], opts) do
    case Fleet.stop(key) do
      :ok ->
        :ok = Audit.record({:agent_stopped, key}, opts[:by])
        {:ok, stopped(key, WardrikDaemon.declared()[key])}

      {:error, :noproc} ->
        {:error, no_agent(key)}

      {:error, reason} ->
        {:error, "#{key} did not stop: #{inspect(reason)}"}
    end
  end

  defp stopped(key, nil),
    do: "Stopped #{key}, and kept its conversation. #{spawn_line(key)} starts it again."

  defp stopped(key, {path, _spec}),
    do:
      "Stopped #{key}, and kept its conversation. #{shown(path)} declares it, so wardrik " <>
        "reload, or #{spawn_line(key)}, starts it again."

  defp spawn_line(%AgentID{org: org, user: user, name: name}) do
    Enum.join(
      ["wardrik agent spawn", name] ++
        if(org != WardrikDaemon.Config.org(), do: ["--org", org], else: []) ++
        if(user, do: ["--user", user], else: []),
      " "
    )
  end

  # -- rm -----------------------------------------------------------------------

  defp rm([target], opts) do
    with {:ok, removing, kept} <- removal(target) do
      if opts[:yes], do: removed(removing, kept, opts[:by]), else: :live
    end
  end

  defp rm_asked([target], opts, terminal) do
    with {:ok, removing, kept} <- removal(target) do
      if terminal.input?,
        do: rm_confirmed(removing, kept, terminal, opts[:by]),
        else:
          {:error,
           [
             removing(removing, kept),
             "\nwardrik agent rm asks first only where someone can answer; ",
             "wardrik agent rm #{target} --yes removes without asking."
           ]}
    end
  end

  defp rm_confirmed(removing, kept, terminal, by) do
    Terminal.puts(terminal, removing(removing, kept))

    if Owl.IO.confirm(message: "Remove #{them(removing)}?", default: false),
      do: removed(removing, kept, by),
      else: {:ok, "Nothing was removed."}
  end

  # What a removal reaches: the agents under the key or prefix that no file
  # declares, here or on a node connected to this one, and why each of the
  # others stays.
  defp removal(target) do
    declared = WardrikDaemon.declared()
    staying = target |> targets() |> Enum.map(&{&1, staying(&1, declared)})
    removing = for {key, nil} <- staying, do: key
    kept = for {_key, why} <- staying, why != nil, do: why

    cond do
      removing != [] -> {:ok, removing, kept}
      kept != [] -> {:error, Enum.join(kept, "\n")}
      prefix?(target) -> {:error, "Nothing runs under #{target}."}
      true -> {:error, no_agent(target)}
    end
  end

  defp targets(target) do
    cond do
      prefix?(target) -> Enum.map(Fleet.list(target), & &1.id)
      Fleet.stored?(target) -> [target]
      true -> []
    end
  end

  defp removing([key], kept),
    do: ["This removes #{key}, its conversation and its schedules, for good." | left(kept)]

  defp removing(keys, kept) do
    [
      "This removes #{length(keys)} agents, their conversations and their schedules, for good:"
      | Enum.map(keys, &"\n  #{&1}")
    ] ++ left(kept)
  end

  defp left(kept), do: for(why <- kept, do: ["\n", why])

  # Why the agent under `key` stays, where a file declares it: one here, or
  # one another node reads.
  defp staying(key, declared) do
    case Map.fetch(declared, key) do
      {:ok, {path, _spec}} ->
        "#{key} is declared by #{shown(path)}, and stays; remove #{shown(path)}, then " <>
          "wardrik reload removes it."

      :error ->
        case Agents.editable(key) do
          :ok -> nil
          {:error, :conflict, message} -> message
        end
    end
  end

  defp them([_one]), do: "it"
  defp them(_keys), do: "them"

  defp removed(removing, kept, by) do
    {gone, failed} =
      removing
      |> Enum.map(&{&1, forget(&1, by)})
      |> Enum.split_with(&match?({_key, :ok}, &1))

    lines =
      if(gone == [], do: [], else: ["Removed #{listed(Enum.map(gone, &elem(&1, 0)))}."]) ++
        kept ++
        for {key, {:error, reason}} <- failed, do: "#{key} was not removed: #{inspect(reason)}"

    if failed == [], do: {:ok, Enum.join(lines, "\n")}, else: {:error, Enum.join(lines, "\n")}
  end

  defp forget(key, by) do
    with :ok <- Fleet.forget(key),
         :ok <- Audit.record({:agent_forgotten, key}, by),
         do: Agents.drop(key)
  end

  # -- move ---------------------------------------------------------------------

  defp move([key | named], opts) do
    with {:ok, member} <- member(key),
         {:ok, node} <- destination(member, named, nil) do
      cond do
        node == member.node -> {:ok, "#{key} runs on #{Nodes.display(node)} already."}
        member.status == :idle or opts[:yes] -> moved(key, node, opts[:by])
        true -> :live
      end
    end
  end

  defp move_asked([key | named], opts, terminal) do
    with {:ok, member} <- member(key),
         {:ok, node} <- destination(member, named, terminal) do
      cond do
        node == member.node -> {:ok, "#{key} runs on #{Nodes.display(node)} already."}
        member.status == :idle or opts[:yes] -> moved(key, node, opts[:by])
        terminal.input? -> confirmed(member, node, terminal, opts[:by])
        true -> {:error, "#{interrupting(member)} #{move_line(key, node)} --yes moves it anyway."}
      end
    end
  end

  defp confirmed(member, node, terminal, by) do
    Terminal.puts(terminal, interrupting(member))

    if Owl.IO.confirm(message: "Move it to #{Nodes.display(node)}?", default: false),
      do: moved(member.id, node, by),
      else: {:ok, "Nothing was moved."}
  end

  defp move_line(key, node), do: "wardrik agent move #{key} #{Nodes.display(node)}"

  defp member(key) do
    case Fleet.lookup(key) do
      nil -> {:error, no_agent(key)}
      member -> {:ok, member}
    end
  end

  # The node a move is for: the one named, or one asked for where none is,
  # which needs the terminal.
  defp destination(_member, [name], _terminal), do: named_node(name)

  defp destination(_member, [], nil), do: :live

  defp destination(member, [], terminal) do
    case CLI.daemons() -- [member.node] do
      [] ->
        {:error,
         "#{Nodes.display(member.node)} is the only node, so there is nowhere to move " <>
           "#{member.id} to."}

      others when terminal.input? ->
        {:ok,
         Owl.IO.select(others,
           label: "Move #{member.id} from #{Nodes.display(member.node)} to which node?",
           render_as: &Nodes.display/1
         )}

      others ->
        {:error,
         "wardrik agent move asks which node only where someone can answer; name it, as in " <>
           "#{move_line(member.id, hd(others))}. The nodes are #{nodes(others)}."}
    end
  end

  defp interrupting(%{status: :running, id: key}),
    do: "#{key} is taking a turn, which moving it ends; what it has said so far is kept."

  defp interrupting(%{id: key}),
    do: "#{key} is waiting on a person, and moving it abandons what it waits for."

  defp moved(key, node, by) do
    case Fleet.move(key, node) do
      {:ok, _pid} ->
        :ok = Audit.record({:agent_moved, key, node}, by)
        {:ok, "Moved #{key} to #{Nodes.display(node)}, with its conversation."}

      {:error, reason} ->
        {:error, "#{key} was not moved: #{inspect(reason)}"}
    end
  end

  # -- edit ---------------------------------------------------------------------

  @doc """
  Where the file that declares the agent under `key` is, for `bin/wardrik` to
  open in an editor, or why there is none.
  """
  @spec file(Wardrik.AgentID.t()) :: {:ok, Path.t()} | {:error, String.t()}
  def file(key) do
    case {WardrikDaemon.declared()[key], Fleet.lookup(key)} do
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
    daemons = CLI.daemons()

    case Nodes.find(name, daemons) do
      nil -> {:error, "No node #{name} runs wardrik; the nodes are #{nodes(daemons)}."}
      node -> {:ok, node}
    end
  end

  defp nodes(daemons), do: daemons |> Enum.map(&Nodes.display/1) |> listed()

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
