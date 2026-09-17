defmodule TarsTUI.App.PaletteFlow do
  @moduledoc """
  Choice lists and command argument collection for the palette.
  """

  alias TarsTUI.Command
  alias TarsTUI.Palette
  alias TarsTUI.Text
  alias TarsTUI.Transcript
  alias TarsTUI.View
  @faint [:faint, :light_black]

  @doc "Rows for the current step, using an explicit snapshot of available choices."
  def choices(%Palette{} = palette, context),
    do: choices_for(Map.put(context, :palette, palette))

  @doc "Returns the next palette action without executing a command or changing focus."
  def select(%{step: :text, command: command, chosen: chosen, query: query}, _choice, _parked),
    do: run(command, chosen ++ [String.trim(query)])

  def select(_palette, nil, _parked), do: :ignore
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

  # With nothing typed the keys come first; with a query, the commands do.
  defp choices_for(%{palette: %{step: :help, query: query, origin: origin}} = assigns) do
    context = context(assigns)
    keys = Enum.map(View.help_keys(origin), &{:key, &1})

    commands =
      Enum.map(
        Command.all(),
        &{{:command, &1}, View.help_command(&1, Command.available?(&1, context))}
      )

    rows = if query == "", do: keys ++ commands, else: commands ++ keys
    Palette.filter(rows, query, fn {_value, row} -> Text.plain(row) end)
  end

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
      attention: Enum.count(assigns.fleet, &TarsTUI.Fleet.attention?(&1, assigns.unseen))
    }
  end
end
