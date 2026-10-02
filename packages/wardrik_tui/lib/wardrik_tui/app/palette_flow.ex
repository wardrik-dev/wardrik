defmodule WardrikTUI.App.PaletteFlow do
  @moduledoc """
  Choice lists and command argument collection for the palette.

  The rows live in the `choices` assign. `refresh/1` fills it from the palette
  and from what its step chooses from; every change to either goes through it,
  and a closed palette leaves it empty. A row is `{value, row}`, the value
  being what the command is given, or `{:header, row}` and `{:blank, row}`, a
  section heading and the air around it, neither of which can be chosen;
  `refresh/1` keeps the cursor off them.
  """
  import Breeze.View, only: [assign: 2]

  alias WardrikTUI.Command
  alias WardrikTUI.Palette
  alias WardrikTUI.Text
  alias WardrikTUI.Transcript
  alias WardrikTUI.View
  @faint [:faint, :light_black]

  @doc "The rows for the palette as it stands now, in the `choices` assign."
  def refresh(%{assigns: %{palette: nil}} = term), do: assign(term, choices: [])

  def refresh(term) do
    choices = choices(term.assigns.palette, snapshot(term))
    palette = %{term.assigns.palette | cursor: land(choices, term.assigns.palette.cursor)}
    assign(term, choices: choices, palette: palette)
  end

  @doc "The rows of `choices` that are headings or air rather than choices."
  @spec skipped([tuple()]) :: [non_neg_integer()]
  def skipped(choices) do
    choices
    |> Enum.with_index()
    |> Enum.flat_map(fn
      {{kind, _row}, index} when kind in [:header, :blank] -> [index]
      {_choice, _index} -> []
    end)
  end

  # The nearest row to `cursor` that can be chosen, at or after it by choice.
  defp land(choices, cursor) do
    rows = Enum.to_list(0..(length(choices) - 1)//1) -- skipped(choices)
    Enum.find(rows, fn row -> row >= cursor end) || List.last(rows) || 0
  end

  # What the steps choose from, as the view has it now.
  defp snapshot(%{assigns: assigns}) do
    assigns
    |> Map.take([:recent, :fleet, :unseen, :running?, :parked, :confirm, :transcript, :tools])
    |> Map.put(:nodes, [node() | Node.list()])
  end

  @doc "Rows for the current step, using an explicit snapshot of available choices."
  def choices(%Palette{} = palette, context),
    do: choices_for(Map.put(context, :palette, palette))

  @doc "Returns the next palette action without executing a command or changing focus."
  def select(%{step: :text, command: command, chosen: chosen, query: query}, _choice, _parked),
    do: run(command, chosen ++ [String.trim(query)])

  def select(_palette, nil, _parked), do: :ignore
  def select(_palette, {kind, _row}, _parked) when kind in [:header, :blank], do: :ignore
  def select(%{step: :commands}, {command, _row}, parked), do: advance(command, [], parked)

  def select(%{step: :help}, {{:command, command}, _row}, parked),
    do: advance(command, [], parked)

  def select(%{step: :help}, {:key, _row}, _parked), do: :ignore
  def select(%{step: :search, query: query}, {row, _text}, _parked), do: {:search, query, row}

  def select(%{step: :tool, origin: origin}, {index, _row}, _parked),
    do: {:inspect_tool, index, origin}

  def select(%{command: command, chosen: chosen}, {value, _row}, parked),
    do: advance(command, chosen ++ [value], parked)

  # One parked call needs no choosing.
  defp advance(command, chosen, parked) do
    case {Enum.at(command.arguments, length(chosen)), parked} do
      {nil, _calls} -> run(command, chosen)
      {:call, [_only]} -> run(command, chosen)
      {step, _calls} -> {:step, step, command, chosen}
    end
  end

  # Produce the same line the prompt parser accepts, including node= arguments.
  defp run(command, chosen) do
    words =
      command.arguments
      |> Enum.zip(chosen)
      |> Enum.map(fn
        {:node, name} -> "node=" <> name
        {_step, value} -> value
      end)
      |> Enum.reject(&(&1 == ""))

    {:run, command, Enum.join([command.name | words], " ")}
  end

  # What the palette offers at its step, narrowed to the query: `{value, row}`
  # pairs, the value being what the command is given.
  defp choices_for(%{palette: %{step: :commands, query: query}} = assigns) do
    recent = assigns.recent

    {first, rest} =
      assigns |> context() |> Command.palette() |> Enum.split_with(&(&1.name in recent))

    first
    |> Enum.sort_by(&Enum.find_index(recent, fn name -> name == &1.name end))
    |> Kernel.++(rest)
    |> Enum.map(&{&1, View.palette_command(&1, &1.name in recent)})
    |> Palette.filter(query, fn {command, _row} -> command.label <> " " <> command.name end)
  end

  defp choices_for(%{palette: %{step: :agent, query: query}} = assigns) do
    assigns.fleet
    |> Enum.map(&{&1.key, agent_row(&1)})
    |> Palette.filter(query, &elem(&1, 0))
  end

  defp choices_for(%{palette: %{step: :node, query: query}, nodes: nodes}) do
    nodes
    |> Enum.map(&{Atom.to_string(&1), node_row(&1)})
    |> Palette.filter(query, &elem(&1, 0))
  end

  defp choices_for(%{palette: %{step: :call, query: query}} = assigns) do
    assigns.parked
    |> Enum.with_index(1)
    |> Enum.map(fn {{call, prompt}, index} -> {"#{index}", call_row(call, prompt, index)} end)
    |> Palette.filter(query, fn {_index, row} -> Text.plain(row) end)
  end

  defp choices_for(%{palette: %{step: :text}}), do: []

  defp choices_for(%{palette: %{step: :search, query: query}} = assigns) do
    assigns.transcript
    |> Transcript.find(query)
    |> Enum.map(fn {row, text} -> {row, View.search_row(row, text)} end)
  end

  defp choices_for(%{palette: %{step: :tool, query: query}} = assigns) do
    assigns.tools
    |> Enum.with_index(1)
    |> Enum.map(fn {exchange, index} -> {index, View.tool_row(exchange, index)} end)
    |> Palette.filter(query, fn {_index, row} -> Text.plain(row) end)
  end

  # Help comes in sections, each narrowed on its own so that one empty of
  # matches drops out with its heading.
  defp choices_for(%{palette: %{step: :help, query: query, origin: origin}} = assigns) do
    origin
    |> help_sections(context(assigns), query)
    |> Enum.map(fn {heading, rows} ->
      {heading, Palette.filter(rows, query, fn {_value, row} -> Text.plain(row) end)}
    end)
    |> Enum.reject(fn {_heading, rows} -> rows == [] end)
    |> Enum.with_index()
    |> Enum.flat_map(fn {{heading, rows}, section} ->
      air(section > 0) ++ [{:header, heading}, {:blank, ""}] ++ rows
    end)
  end

  # Every heading stands clear of the section above it, the first one having
  # the rule under the query for that.
  defp air(true), do: [{:blank, ""}]
  defp air(false), do: []

  # With nothing typed the keys that work here come first, then the commands;
  # with a query, the commands come first. What cannot run now comes last.
  defp help_sections(origin, context, query) do
    {available, not_now} = Enum.split_with(Command.all(), &Command.available?(&1, context))
    [here | elsewhere] = Enum.map(View.help_panes(origin), &keys_section(&1, origin))
    anywhere = keys_section(nil, origin)
    commands = [{View.help_section("commands", origin), help_commands(available, true)}]

    Enum.reject(
      if(query == "", do: [here, anywhere], else: []) ++
        commands ++
        if(query == "", do: [], else: [here, anywhere]) ++
        elsewhere ++
        [{View.help_section("not right now", origin), help_commands(not_now, false)}],
      fn {_heading, rows} -> rows == [] end
    )
  end

  defp keys_section(where, origin),
    do:
      {View.help_section(where || "anywhere", origin),
       Enum.map(View.help_keys(where), &{:key, &1})}

  defp help_commands(commands, available?),
    do: Enum.map(commands, &{{:command, &1}, View.help_command(&1, available?)})

  defp agent_row(member) do
    elsewhere = if member.node == node(), do: "", else: " · @#{short_node(member.node)}"
    [Text.tag(member.key, :bright), Text.tag("  #{member.status}#{elsewhere}", @faint)]
  end

  defp node_row(name) do
    [
      Text.tag(Atom.to_string(name), :bright),
      if(name == node(), do: Text.tag("  this node", @faint), else: [])
    ]
  end

  defp call_row(call, prompt, index),
    do: [
      Text.tag("#{index}  ", @faint),
      Text.tag(call.name, :bright),
      Text.tag("  #{prompt}", @faint)
    ]

  defp short_node(node), do: node |> Atom.to_string() |> String.split("@", parts: 2) |> hd()

  defp context(assigns) do
    %{
      busy?: assigns.running? or assigns.parked != [],
      parked: length(assigns.parked),
      confirm?: assigns.confirm != nil,
      nodes: length(assigns.nodes),
      attention: Enum.count(assigns.fleet, &WardrikTUI.Fleet.attention?(&1, assigns.unseen))
    }
  end
end
