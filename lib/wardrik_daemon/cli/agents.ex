defmodule WardrikDaemon.CLI.Agents do
  @moduledoc """
  `wardrik ls`, `show` and `schedules`: the fleet's agents a line each, one
  agent in full, and when each schedule asks its agent.

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
  alias WardrikConsole.Filter
  alias WardrikConsole.Nodes
  alias WardrikDaemon.CLI.Command
  alias WardrikHTTP.Resource
  alias WardrikPolicy.Pattern

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
        name: "schedules",
        arguments: "[PREFIX]",
        summary: "when each schedule runs next, and how it last ran",
        count: {0, 1},
        run: &schedules/2
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
    specs = WardrikDaemon.specs()
    headings = ["AGENT", "STATUS", "NODE", "NEXT RUN", "SPENT"]

    rows =
      for member <- members do
        [
          Owl.Data.tag(member.key, :bright),
          status(member),
          Nodes.display(member.node),
          next(member.key),
          Enum.join(WardrikDaemon.spent(specs[member.key], member.key), ", ")
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

  defp status(%{status: :parked}), do: Owl.Data.tag("parked", [:bright, :yellow])
  defp status(%{status: :running}), do: Owl.Data.tag("running", :cyan)
  defp status(%{outcome: :failed}), do: Owl.Data.tag("idle, last failed", :red)
  defp status(%{status: status}), do: Owl.Data.tag(to_string(status), @faint)

  defp next(key) do
    case WardrikDaemon.next_in(key) do
      nil -> ""
      ms -> "in " <> WardrikDaemon.duration(ms)
    end
  end

  # -- show ---------------------------------------------------------------------

  defp show([key], _opts) do
    case {Fleet.lookup(key), Agent.snapshot(key)} do
      {nil, _snapshot} -> {:error, "No agent runs under #{key}."}
      {_member, {:error, :not_found}} -> {:error, "No agent runs under #{key}."}
      {member, snapshot} -> {:ok, &shown(member, snapshot, file(key), &1)}
    end
  end

  defp file(key) do
    Enum.find_value(WardrikDaemon.agent_files(), fn
      {path, {:ok, %Wardrik.Agent.Spec{} = spec}} ->
        if Wardrik.Agent.Spec.key(spec) == key, do: {path, spec}

      _other ->
        nil
    end)
  end

  defp shown(member, snapshot, file, width) do
    rows =
      [
        {"status", doing(member, snapshot)},
        {"model", model(snapshot)}
      ] ++ given(file, member.key) ++ asked(member.key) ++ waiting(snapshot) ++ written(file)

    column = rows |> Enum.map(&String.length(elem(&1, 0))) |> Enum.max()

    lines =
      for {label, value} <- rows do
        [Owl.Data.tag(String.pad_trailing(label, column), @faint), "  ", value]
      end

    lines
    |> described(file)
    |> Enum.intersperse("\n")
    |> Owl.Box.new(
      title: Owl.Data.tag(member.key, :bright),
      border_style: :solid_rounded,
      padding_x: 1,
      max_width: width,
      word_wrap: :normal
    )
  end

  defp described(lines, {_path, %{description: description}}) when is_binary(description),
    do: [description, "" | lines]

  defp described(lines, _file), do: lines

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

  # What the agent's file gives it: tools, a policy, and budgets.
  defp given(nil, _key),
    do: [{"file", Owl.Data.tag("none; it was defined over the HTTP API", @faint)}]

  defp given({_path, spec}, key) do
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
    for schedule <- Wardrik.Schedule.for_agent(key), do: {"schedule", schedule(schedule, now)}
  end

  defp waiting(snapshot) do
    for {call, prompt} <- snapshot.parked,
        do:
          {"waiting",
           [call.id, "  ", Pattern.shown(call.name), "  ", Owl.Data.tag(prompt, @faint)]}
  end

  defp written({path, _spec}), do: [{"file", path}]
  defp written(nil), do: []

  # -- schedules ----------------------------------------------------------------

  defp schedules(words, _opts) do
    prefix = List.first(words, "")
    now = DateTime.utc_now()

    rows =
      for schedule <- Wardrik.Schedule.list(prefix),
          do: "  #{schedule.key}  #{schedule(schedule, now)}"

    case rows do
      [] -> {:ok, "Nothing is scheduled#{if prefix != "", do: " under #{prefix}"}."}
      [_row] -> {:ok, Enum.join(["1 schedule:" | rows], "\n")}
      rows -> {:ok, Enum.join(["#{length(rows)} schedules:" | rows], "\n")}
    end
  end

  defp schedule(schedule, now) do
    next = WardrikDaemon.duration(max(DateTime.diff(schedule.next_at, now, :millisecond), 0))
    "#{every(schedule.every)}  next in #{next}  #{ran(schedule, now)}"
  end

  defp every({:cron, text}), do: text
  defp every({:interval, ms}), do: "every " <> interval(ms)

  defp interval(ms) when rem(ms, 86_400_000) == 0, do: "#{div(ms, 86_400_000)}d"
  defp interval(ms) when rem(ms, 3_600_000) == 0, do: "#{div(ms, 3_600_000)}h"
  defp interval(ms) when rem(ms, 60_000) == 0, do: "#{div(ms, 60_000)}m"
  defp interval(ms), do: "#{ms}ms"

  defp ran(%{last_at: nil, last_outcome: nil}, _now), do: "not run yet"
  defp ran(%{last_at: nil, last_outcome: outcome}, _now), do: "last: " <> outcome(outcome)

  defp ran(%{last_at: at, last_outcome: outcome}, now) do
    ago = WardrikDaemon.duration(max(DateTime.diff(now, at, :millisecond), 0))
    "last run #{ago} ago: " <> outcome(outcome)
  end

  defp outcome(nil), do: "asking"
  defp outcome(:asked), do: "asked"
  defp outcome(:busy), do: "skipped, the agent was busy"
  defp outcome(:no_agent), do: "no agent runs under the key"
  defp outcome(:missed), do: "let a missed run go"
  defp outcome(:failed), do: "failed to ask"
end
