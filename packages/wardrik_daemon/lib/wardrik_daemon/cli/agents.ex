defmodule WardrikDaemon.CLI.Agents do
  @moduledoc """
  `wardrik ls`, `show` and `triggers`: the fleet's agents a line each, one
  agent in full, and when each trigger asks its agent.

  `ls` takes the words the TUI's `/filter` does, as `WardrikConsole.Filter`
  reads them, where `attention` is an agent waiting on a person. `show KEY`
  says what the agent is doing, on which node, with which model, what its
  file gives it, what it has spent, when it is asked next, and what it waits
  on. An agent defined over the HTTP API has no file, so what one gives it is
  not shown.
  """

  alias Wardrik.Agent
  alias Wardrik.Event.Codec.Value
  alias Wardrik.Fleet
  alias Wardrik.Fleet.Member
  alias Wardrik.JSON
  alias WardrikConsole.Filter
  alias WardrikConsole.Nodes
  alias WardrikDaemon.CLI.Command
  alias WardrikDaemon.Config
  alias WardrikDefinition.Record
  alias WardrikPolicy.Pattern
  alias WardrikTrigger.Status

  @faint [:faint, :light_black]

  @doc "The commands about agents, for `WardrikDaemon.CLI.commands/0`."
  @spec commands() :: [Command.t()]
  def commands do
    [
      %Command{
        name: "ls",
        group: "Manage agents",
        arguments: "[QUERY]",
        summary: "the agents, or those a query picks",
        details: [
          "A query is words that must all match: TEXT in the key, name:, org:, user:,",
          "node:, status:idle, status:running or status:parked, and attention, an",
          "agent waiting on a person. With --json, the agents as GET /v1/agents",
          "lists them."
        ],
        count: {0, :any},
        run: &ls/2,
        json: &listed/2
      },
      %Command{
        name: "show",
        group: "Manage agents",
        arguments: "KEY",
        summary: "one agent in full: what it has and what it is doing",
        count: {1, 1},
        run: &show/2
      },
      %Command{
        name: "triggers",
        group: "Manage agents",
        arguments: "[PATTERN]",
        summary: "when each trigger runs next, and how it last ran",
        count: {0, 1},
        run: &triggers/2
      }
    ]
  end

  # -- ls -----------------------------------------------------------------------

  defp ls(words, opts) do
    with {:ok, members} <- picked(words, opts) do
      case members do
        [] when words == [] -> {:ok, "No agents."}
        [] -> {:ok, "No agent matches #{Enum.join(words, " ")}."}
        members -> {:ok, table(Wardrik.Host.store(opts[:as].host), members)}
      end
    end
  end

  defp listed(words, opts) do
    with {:ok, members} <- picked(words, opts),
         do: {:ok, %{"agents" => Enum.map(members, &JSON.agent/1)}}
  end

  defp picked(words, opts) do
    case Filter.parse(Enum.join(words, " ")) do
      {:ok, filter} ->
        members = Fleet.list(Wardrik.Resource.parse!("*"), host: opts[:as].host)
        {:ok, Enum.filter(members, &Filter.match?(filter, &1, &1.status == :parked))}

      {:error, word} ->
        {:error,
         "#{word} is not a word a query takes: TEXT, name:, org:, user:, node:, " <>
           "status:idle, status:running, status:parked or attention"}
    end
  end

  # A column for each thing any agent listed has, the key, status and node
  # always, under a faint heading.
  defp table(_store, members) do
    headings = ["AGENT", "STATUS", "NODE", "NEXT RUN", "SPENT"]

    rows =
      for member <- members do
        [
          Owl.Data.tag(to_string(member.id), :bright),
          status(member),
          where(member),
          next(member.id),
          Enum.join(WardrikDaemon.spent(WardrikDaemon.Host.agents(), member.id), ", ")
        ]
      end

    kept =
      [Enum.map(headings, &Owl.Data.tag(&1, @faint)) | rows]
      |> Enum.zip()
      |> Enum.map(&Tuple.to_list/1)
      |> Enum.reject(fn [_heading | cells] -> Enum.all?(cells, &(&1 == "")) end)

    kept |> Enum.zip_with(& &1) |> lined_up()
  end

  # Rows of cells in columns two spaces apart, with nothing after a row's last
  # cell that holds anything.
  defp lined_up(rows) do
    widths =
      Enum.zip_with(rows, fn column -> column |> Enum.map(&Owl.Data.length/1) |> Enum.max() end)

    rows
    |> Enum.map(fn cells ->
      cells
      |> Enum.zip(widths)
      |> Enum.reverse()
      |> Enum.drop_while(fn {cell, _width} -> cell == "" end)
      |> Enum.reverse()
      |> Enum.map_intersperse("  ", fn {cell, width} ->
        [cell, String.duplicate(" ", width - Owl.Data.length(cell))]
      end)
      |> trimmed()
    end)
    |> Enum.intersperse("\n")
  end

  # The last cell is not padded.
  defp trimmed([]), do: []
  defp trimmed(cells), do: List.update_at(cells, -1, fn [cell, _padding] -> cell end)

  @colours %{parked: [:bright, :yellow], running: :cyan, failed: :red}

  defp status(member),
    do: Owl.Data.tag(Member.label(member), Map.get(@colours, Member.state(member), @faint))

  defp next(key) do
    case WardrikDaemon.next_in(key) do
      nil -> ""
      ms -> "in " <> WardrikDaemon.duration(ms)
    end
  end

  # -- show ---------------------------------------------------------------------

  # The snapshot wakes an agent asleep, so the fleet then shows it awake.
  defp show([key], opts) do
    host = opts[:as].host

    case Agent.snapshot(key, host: host) do
      {:error, :not_found} -> {:error, "No agent runs under #{key}."}
      snapshot -> {:ok, &shown(Fleet.lookup(key, host: host), snapshot, defined(opts, key), &1)}
    end
  end

  # The definition the agent runs on, with the spec it writes now or why it
  # writes none, and the tools it names that offer nothing yet, or `nil`
  # where none is kept.
  defp defined(opts, key) do
    case Record.of(Wardrik.Host.store(opts[:as].host), key) do
      {:ok, definition} ->
        agents = WardrikDaemon.Host.agents()
        {:ok, read} = Wardrik.Definition.get(agents, definition.id)
        {definition, WardrikDaemon.Agents.build(agents, definition, key), read.missing}

      {:error, :not_found} ->
        nil
    end
  end

  defp shown(member, snapshot, defined, width) do
    rows =
      [
        {"status", doing(member, snapshot)},
        {"model", model(snapshot)}
      ] ++
        given(defined, member.id) ++
        asked(member.id) ++ waiting(snapshot) ++ written(defined, member.id)

    column = rows |> Enum.map(&String.length(elem(&1, 0))) |> Enum.max()

    lines =
      for {label, value} <- rows do
        [Owl.Data.tag(String.pad_trailing(label, column), @faint), "  ", value]
      end

    lines
    |> described(defined)
    |> Enum.intersperse("\n")
    |> Owl.Box.new(
      title: Owl.Data.tag(to_string(member.id), :bright),
      border_style: :solid_rounded,
      padding_x: 1,
      max_width: width,
      word_wrap: :normal
    )
  end

  defp described(lines, {%Record{fields: %{"description" => description}}, _spec, _missing})
       when is_binary(description),
       do: [description, "" | lines]

  defp described(lines, _defined), do: lines

  defp where(%{asleep: true}), do: ""
  defp where(member), do: Nodes.display(member.node)

  defp doing(member, snapshot) do
    [
      status(member),
      " on ",
      Nodes.display(member.node),
      waiting_messages(snapshot.status.pending),
      last(snapshot.outcome)
    ]
  end

  defp waiting_messages(0), do: []
  defp waiting_messages(1), do: ", 1 message waiting"
  defp waiting_messages(count), do: ", #{count} messages waiting"

  defp last(:failed), do: Owl.Data.tag("; its last turn failed", :red)
  defp last(:interrupted), do: "; its last turn was stopped"
  defp last(_outcome), do: []

  defp model(snapshot) do
    case Value.model(snapshot.status.model) do
      {nil, model} -> model
      {provider, model} -> "#{provider}:#{model}"
    end
  end

  # What the agent's definition gives it: tools, a policy, and budgets.
  defp given(nil, _key),
    do: [{"definition", Owl.Data.tag("none kept; it was started without one", @faint)}]

  defp given({_definition, {:error, message}, _missing}, _key),
    do: [{"definition", Owl.Data.tag("does not build: " <> message, :red)}]

  defp given({_definition, {:ok, spec}, missing}, key) do
    policies =
      for %Wardrik.Hook{module: module} = hook <- spec.hooks,
          module not in [WardrikPolicy.Budget, WardrikPolicy.Ceiling],
          do: {"policy", policy(hook)}

    policies =
      if policies == [],
        do: [{"policy", Owl.Data.tag("none; any call its tools allow runs", @faint)}],
        else: policies

    [{"tools", tools(spec)} | missing(missing)] ++
      policies ++ for spent <- WardrikDaemon.spent_by(spec, key), do: {"budget", spent}
  end

  defp missing(names) do
    for name <- names,
        do:
          {"missing",
           [name, "  ", Owl.Data.tag("offers nothing until its owner adds it", @faint)]}
  end

  # A policy by its name, or as the file's own, with how many rules of each
  # kind it has and what it does with a call none matches.
  defp policy(%Wardrik.Hook{module: WardrikPolicy, value: %WardrikPolicy{} = policy}) do
    counts =
      for effect <- [:allow, :ask, :deny],
          count = Enum.count(policy.rules, &(&1.effect == effect)),
          count > 0,
          do: "#{count} #{effect}"

    rules = if counts == [], do: "no rules", else: Enum.join(counts, ", ")
    "#{policy.name || "the file's own"}: #{rules}; otherwise #{policy.default}"
  end

  defp policy(%Wardrik.Hook{name: name}), do: name

  defp tools(spec) do
    case spec.config |> Wardrik.LLM.Config.tools() |> Enum.map(&Pattern.shown(&1.name)) do
      [] -> Owl.Data.tag("none", @faint)
      names -> names |> Enum.split(8) |> tool_names()
    end
  end

  # The first eight by name, and how many more there are.
  defp tool_names({names, []}), do: Enum.join(names, ", ")
  defp tool_names({names, more}), do: [Enum.join(names, ", "), " and #{length(more)} more"]

  defp asked(key) do
    now = DateTime.utc_now()
    for trigger <- WardrikTrigger.for_agent(key), do: {"trigger", trigger(trigger, now)}
  end

  defp waiting(snapshot) do
    for {call, prompt} <- snapshot.parked,
        do:
          {"waiting",
           [call.id, "  ", Pattern.shown(call.name), "  ", Owl.Data.tag(prompt, @faint)]}
  end

  # Where the definition was written, and whose it is for a conversation.
  defp written(nil, _key), do: []

  defp written({%Record{id: owner, source: source}, _spec, _missing}, key) do
    conversation = if owner == key, do: [], else: [{"conversation", "of #{owner}"}]
    conversation ++ [{"file", source(owner, source)}]
  end

  defp source(owner, {:file, name}) do
    case WardrikDaemon.Host.declared()[owner] do
      {path, _spec} -> path
      nil -> Path.join("agents", name)
    end
  end

  defp source(_owner, {:api, _token}),
    do: Owl.Data.tag("none; it was defined over the HTTP API", @faint)

  defp source(_owner, :defaults),
    do: Owl.Data.tag("none; it was made from config.yaml's defaults", @faint)

  # -- triggers ----------------------------------------------------------------

  defp triggers(words, _opts) do
    pattern = List.first(words, Wardrik.Resource.parse!("*"))
    now = DateTime.utc_now()

    rows =
      for trigger <- WardrikTrigger.list(pattern),
          do: "  #{trigger.agent}/#{trigger.name}  #{trigger(trigger, now)}"

    case rows do
      [] -> {:ok, "No agent #{pattern} covers has a trigger."}
      [_row] -> {:ok, Enum.join(["1 trigger:" | rows], "\n")}
      rows -> {:ok, Enum.join(["#{length(rows)} triggers:" | rows], "\n")}
    end
  end

  defp trigger(trigger, now) do
    next =
      for at <- trigger.next,
          do: "  next in #{WardrikDaemon.duration(max(DateTime.diff(at, now, :millisecond), 0))}"

    urls =
      for path <- trigger.paths, do: "  " <> Config.base_url(WardrikDaemon.Host.config()) <> path

    "#{trigger.schedule}#{next}#{urls}  #{ran(trigger, now)}"
  end

  defp ran(%{last_at: nil, last_outcome: nil}, _now), do: "not run yet"

  defp ran(%{last_at: nil, last_outcome: outcome}, _now),
    do: "last: " <> Status.described(outcome)

  defp ran(%{last_at: at, last_outcome: outcome}, now) do
    ago = WardrikDaemon.duration(max(DateTime.diff(now, at, :millisecond), 0))
    "last run #{ago} ago: " <> Status.described(outcome)
  end
end
