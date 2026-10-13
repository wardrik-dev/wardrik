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
  alias Wardrik.Resource
  alias WardrikConsole.Filter
  alias WardrikConsole.Nodes
  alias WardrikDaemon.CLI.Command
  alias WardrikDaemon.Config
  alias WardrikDaemon.Definition
  alias WardrikPolicy.Pattern
  alias WardrikTrigger.Status

  @faint [:faint, :light_black]

  @doc "The commands about agents, for `WardrikDaemon.CLI.commands/0`."
  @spec commands() :: [Command.t()]
  def commands do
    [
      %Command{
        name: "ls",
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
        arguments: "KEY",
        summary: "one agent in full: what it has and what it is doing",
        count: {1, 1},
        run: &show/2
      },
      %Command{
        name: "triggers",
        arguments: "[PREFIX]",
        summary: "when each trigger runs next, and how it last ran",
        count: {0, 1},
        run: &triggers/2
      }
    ]
  end

  # -- ls -----------------------------------------------------------------------

  defp ls(words, _opts) do
    with {:ok, members} <- picked(words) do
      case members do
        [] when words == [] -> {:ok, "No agents."}
        [] -> {:ok, "No agent matches #{Enum.join(words, " ")}."}
        members -> {:ok, table(members)}
      end
    end
  end

  defp listed(words, _opts) do
    with {:ok, members} <- picked(words),
         do: {:ok, %{"agents" => Enum.map(members, &Resource.agent/1)}}
  end

  defp picked(words) do
    case Filter.parse(Enum.join(words, " ")) do
      {:ok, filter} ->
        {:ok, Enum.filter(Fleet.list(), &Filter.match?(filter, &1, &1.status == :parked))}

      {:error, word} ->
        {:error,
         "#{word} is not a word a query takes: TEXT, name:, org:, user:, node:, " <>
           "status:idle, status:running, status:parked or attention"}
    end
  end

  # A column for each thing any agent listed has, the key, status and node
  # always, under a faint heading.
  defp table(members) do
    headings = ["AGENT", "STATUS", "NODE", "NEXT RUN", "SPENT"]

    rows =
      for member <- members do
        [
          Owl.Data.tag(to_string(member.id), :bright),
          status(member),
          where(member),
          next(member.id),
          Enum.join(WardrikDaemon.spent(member.id), ", ")
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
  defp show([key], _opts) do
    case Agent.snapshot(key) do
      {:error, :not_found} -> {:error, "No agent runs under #{key}."}
      snapshot -> {:ok, &shown(Fleet.lookup(key), snapshot, defined(key), &1)}
    end
  end

  # The definition the agent runs on, with the spec it writes now or why it
  # writes none, or `nil` where none is kept.
  defp defined(key) do
    case Definition.of(key) do
      {:ok, definition} -> {definition, WardrikDaemon.Agents.build(definition, key)}
      {:error, :not_found} -> nil
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

  defp described(lines, {%Definition{fields: %{"description" => description}}, _spec})
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

  defp given({_definition, {:error, message}}, _key),
    do: [{"definition", Owl.Data.tag("does not build: " <> message, :red)}]

  defp given({_definition, {:ok, spec}}, key) do
    policies =
      for %Wardrik.Hook{module: module} = hook <- spec.hooks,
          module != WardrikPolicy.Budget,
          do: {"policy", policy(hook)}

    policies =
      if policies == [],
        do: [{"policy", Owl.Data.tag("none; any call its tools allow runs", @faint)}],
        else: policies

    [{"tools", tools(spec)} | policies] ++
      for spent <- WardrikDaemon.spent(spec, key), do: {"budget", spent}
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

  defp written({%Definition{id: owner, source: source}, _spec}, key) do
    conversation = if owner == key, do: [], else: [{"conversation", "of #{owner}"}]
    conversation ++ [{"file", source(owner, source)}]
  end

  defp source(owner, {:file, name}) do
    case WardrikDaemon.declared()[owner] do
      {path, _spec} -> path
      nil -> Path.join("agents", name)
    end
  end

  defp source(_owner, {:api, _grant}),
    do: Owl.Data.tag("none; it was defined over the HTTP API", @faint)

  # -- triggers ----------------------------------------------------------------

  defp triggers(words, _opts) do
    prefix = List.first(words, Wardrik.AgentID.Prefix.all())
    now = DateTime.utc_now()

    rows =
      for trigger <- WardrikTrigger.list(prefix),
          do: "  #{trigger.agent}/#{trigger.name}  #{trigger(trigger, now)}"

    under = to_string(prefix)

    case rows do
      [] -> {:ok, "No agent has a trigger#{if under != "", do: " under #{under}"}."}
      [_row] -> {:ok, Enum.join(["1 trigger:" | rows], "\n")}
      rows -> {:ok, Enum.join(["#{length(rows)} triggers:" | rows], "\n")}
    end
  end

  defp trigger(trigger, now) do
    next =
      for at <- trigger.next,
          do: "  next in #{WardrikDaemon.duration(max(DateTime.diff(at, now, :millisecond), 0))}"

    urls = for path <- trigger.paths, do: "  " <> Config.base_url() <> path

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
