defmodule TarsTUI.App.Interaction do
  @moduledoc """
  Focus, overlays, transcript navigation, clipboard, and transient notices.
  """
  import Breeze.View, only: [assign: 2, focus: 2, put_implicit: 4]

  alias TarsTUI.App.Connection
  alias TarsTUI.Command
  alias TarsTUI.Fleet.Filter
  alias TarsTUI.Markdown
  alias TarsTUI.Palette
  alias TarsTUI.Search
  alias TarsTUI.View
  @notice_after 4_000

  # Opens the palette at the next argument `command` needs after `chosen`,
  # with `query` already typed, as a command missing an argument does.
  def pick(term, name, chosen, query \\ "") do
    command = Command.find(name)
    step = Enum.at(command.arguments, length(chosen))
    palette = %Palette{step: step, command: command, chosen: chosen, query: query}

    term |> open_palette(palette) |> Connection.refresh_fleet()
  end

  # Every key and command over the panes, searched like the palette; Enter on
  # a command runs it.
  def open_help(term),
    do: open_palette(term, %Palette{step: :help, origin: term.focused || "prompt"})

  def open_palette(term, %Palette{} = palette),
    do: term |> assign(palette: palette, leader: nil) |> focus("palette")

  # The transcript's matching rows, narrowed as letters are typed; Enter goes
  # to one.
  def open_search(term, query),
    do:
      open_palette(term, %Palette{step: :search, query: query, origin: term.focused || "prompt"})

  # The conversation's tool calls; Enter opens one in the inspector.
  def open_tools(%{assigns: %{tools: []}} = term), do: flash(term, View.no_tools())

  def open_tools(term),
    do: open_palette(term, %Palette{step: :tool, origin: term.focused || "prompt"})

  def close_palette(%{assigns: %{palette: %{origin: origin}}} = term),
    do: term |> assign(palette: nil) |> focus_pane(origin)

  def close_palette(term), do: term

  def update_palette(%{assigns: %{palette: nil}} = term, _fun), do: term

  def update_palette(term, fun), do: assign(term, palette: fun.(term.assigns.palette))

  # Back to choosing a command, with nothing chosen.
  def restart_palette(term) do
    update_palette(term, &%{&1 | step: :commands, command: nil, chosen: [], query: "", cursor: 0})
  end

  # The agents offered are the fleet as it is now.
  def step_palette(term, step, command, chosen) do
    term = if step == :agent, do: Connection.refresh_fleet(term), else: term

    update_palette(
      term,
      &%{&1 | step: step, command: command, chosen: chosen, query: "", cursor: 0}
    )
  end

  def inspect_delegation(term, key, span_id),
    do: open_inspector(term, {:delegation, key, span_id})

  def inspect_tool(term, index, origin), do: open_inspector(term, {:tool, index, origin})

  defp open_inspector(term, inspecting),
    do: term |> assign(inspecting: inspecting, pane: "inspector") |> focus("inspector")

  # A delegation was opened from the panel; a tool call from wherever `t` or
  # `/tools` was.
  def close_inspector(%{assigns: %{inspecting: {:tool, _index, origin}}} = term),
    do: term |> assign(inspecting: nil) |> focus_pane(origin)

  def close_inspector(term), do: term |> assign(inspecting: nil) |> focus_pane("fleet")

  # The transcript scrolled so `row` is the top one shown, and focused.
  def go_to_row(term, row) do
    term
    |> put_implicit("log", TarsTUI.Scroll, %{
      offset_y: row,
      autoscroll: "bottom",
      pinned_bottom: false
    })
    |> focus_pane("log")
  end

  def step_match(%{assigns: %{search: nil}} = term, _direction),
    do: flash(term, View.nothing_searched())

  def step_match(%{assigns: %{search: search}} = term, direction) do
    case Search.step(search, term.assigns.transcript, direction) do
      :none ->
        flash(term, View.no_match(search.query))

      {search, row, count} ->
        term
        |> assign(search: search)
        |> go_to_row(row)
        |> flash(View.match(search.query, search.at + 1, count))
    end
  end

  # The last answer, or its last code block, on the clipboard.
  def copy_text(term, what) do
    with {:ok, text} <- to_copy(term.assigns.answer_text, what),
         :ok <- term.assigns.clipboard.(text) do
      flash(term, View.copied(what, String.length(text)))
    else
      {:error, why} -> flash(term, View.not_copied(why))
    end
  end

  defp to_copy("", _what), do: {:error, :no_answer}

  defp to_copy(text, :answer), do: {:ok, text}

  defp to_copy(text, :code) do
    case List.last(Markdown.code_blocks(text)) do
      nil -> {:error, :no_code}
      code -> {:ok, code}
    end
  end

  # A notice on the status row for a moment, in place of the transcript.
  def flash(term, text) do
    ref = make_ref()
    Process.send_after(self(), {:notice_timeout, ref}, @notice_after)
    assign(term, notice: {ref, text})
  end

  # Focusing the panel refreshes it first, so the rows are current before the
  # cursor moves through them.
  def focus_pane(term, "fleet"),
    do: term |> Connection.refresh_fleet() |> focus("fleet") |> assign(pane: "fleet")

  def focus_pane(term, id), do: term |> focus(id) |> assign(pane: id)

  # Focus moves without this view hearing of it, on `Tab` for one, so the pane
  # the hints describe is read back whenever the view handles anything.
  def sync_pane(term), do: assign(term, pane: term.focused || "prompt")

  # The panel, shown if it was hidden, with the cursor in it; on a narrow
  # terminal that is the overlay.
  def show_fleet(term), do: term |> assign(sidebar?: true) |> focus_pane("fleet")

  # The agent needing attention after `key`, round the list, or `nil`.
  defp next_needing(assigns, key) do
    case Connection.attention(assigns) do
      [] -> nil
      needing -> Enum.find(needing, hd(needing), &(&1.key > key))
    end
  end

  def next_attention(term) do
    case next_needing(term.assigns, term.assigns.agent_id) do
      nil -> flash(term, View.nothing_needs_attention())
      member -> Connection.connect_key(term, member.key)
    end
  end

  def highlight_next(term) do
    case next_needing(term.assigns, Connection.agent_of(term.assigns.highlighted) || "") do
      nil -> term
      member -> assign(term, highlighted: member.key)
    end
  end

  def filter(term, nil), do: term |> assign(filter: Filter.none()) |> flash(View.unfiltered())

  def filter(term, query) do
    case Filter.parse(query) do
      {:ok, filter} ->
        term = assign(term, filter: filter)
        shown = length(Connection.shown(term.assigns))
        flash(term, View.filtered(Filter.describe(filter), shown, length(term.assigns.fleet)))

      {:error, word} ->
        flash(term, View.bad_filter(word))
    end
  end

  # `a` in the panel: only the agents needing attention, or every agent again.
  def toggle_attention(%{assigns: %{filter: %Filter{query: "attention"}}} = term),
    do: assign(term, filter: Filter.none())

  def toggle_attention(term) do
    {:ok, filter} = Filter.parse("attention")
    assign(term, filter: filter)
  end
end
