defmodule TarsTUI.Palette do
  @moduledoc """
  The command palette: what `TarsTUI.App` keeps of one while it is open, a
  `Breeze.Implicit` for the query line over its rows, and `filter/3` for
  narrowing the rows to the query.

  The struct is the palette as the app has it: `step`, what it is choosing,
  `:commands`, an argument step of `TarsTUI.Command`, or `:help`; `command`
  and `chosen`, the command collecting arguments and those collected so far;
  `query` and `cursor`, what is typed and the row under the cursor; and
  `origin`, the pane focus returns to when it closes.

  The element takes the query, the row under the cursor, how many rows there
  are and which of them are section headings as `palette-query`,
  `palette-cursor`, `palette-count` and `palette-skip`, the last a list of row
  numbers written with commas. Typing and `Backspace` change the query and put
  the cursor on the first row; `Ctrl-W` clears the query. `Up`, `Down`, `Tab`,
  `Shift-Tab`, `Home` and `End` move the cursor, stepping over the headings.
  Each of these sends `%{query: query, cursor: cursor}` through `br-change`.
  `Enter` sends `%{cursor: cursor}` through `br-submit`. `Esc` sends
  `%{action: :close}`, and `Backspace` on an empty query `%{action: :back}`,
  both through `br-change`.
  """

  @behaviour Breeze.Implicit

  alias Breeze.InputCapture
  alias TarsTUI.Command

  defstruct step: :commands, command: nil, chosen: [], query: "", cursor: 0, origin: "prompt"

  @type t() :: %__MODULE__{
          step: :commands | :help | Command.step(),
          command: Command.t() | nil,
          chosen: [String.t()],
          query: String.t(),
          cursor: non_neg_integer(),
          origin: String.t()
        }

  @impl Breeze.Implicit
  def init(_children, root_attrs, last_state) do
    state = %{
      query: Map.get(root_attrs, :"palette-query", ""),
      cursor: integer(Map.get(root_attrs, :"palette-cursor", 0)),
      count: integer(Map.get(root_attrs, :"palette-count", 0)),
      skip: skip(Map.get(root_attrs, :"palette-skip", ""))
    }

    {:ok, Map.merge(last_state, state),
     captures_keys: ["Escape", "Enter", "ArrowUp", "ArrowDown", "Home", "End"],
     captures_printable_keys: true,
     captures_focus_keys: true,
     requires_layout_rerender: true}
  end

  defp integer(value) when is_integer(value), do: value
  defp integer(value) when is_binary(value), do: String.to_integer(value)
  defp integer(_value), do: 0

  defp skip(rows) when is_binary(rows),
    do: rows |> String.split(",", trim: true) |> Enum.map(&String.to_integer/1) |> MapSet.new()

  defp skip(rows) when is_list(rows), do: MapSet.new(rows)
  defp skip(_rows), do: MapSet.new()

  @impl Breeze.Implicit
  def handle_event(_type, %{"key" => "Escape"}, state), do: {{:change, %{action: :close}}, state}

  def handle_event(_type, %{"key" => key}, state) when key in ["Enter", "\r", "\n"],
    do: {{:submit, %{cursor: state.cursor}}, state}

  def handle_event(_type, %{"key" => "\x7f"}, state), do: backspace(state)
  def handle_event(_type, %{"key" => "Backspace"}, state), do: backspace(state)

  def handle_event(_type, %{"key" => key}, state) when key in ["\x08", "\x17"],
    do: query(state, "")

  def handle_event(_type, %{"ctrlKey" => true, "key" => key}, state)
      when key in ["Backspace", "w"],
      do: query(state, "")

  def handle_event(_type, %{"key" => key}, state) when key in ["ArrowUp", "ShiftTab"],
    do: move(state, state.cursor - 1, -1)

  def handle_event(_type, %{"key" => key}, state) when key in ["ArrowDown", "Tab", "\t"],
    do: move(state, state.cursor + 1, 1)

  def handle_event(_type, %{"key" => "Home"}, state), do: move(state, 0, 1)
  def handle_event(_type, %{"key" => "End"}, state), do: move(state, state.count - 1, -1)

  def handle_event(_type, %{"key" => key} = event, state) do
    if InputCapture.printable_key?(event),
      do: query(state, state.query <> key),
      else: {:noreply, state}
  end

  def handle_event(_type, _event, state), do: {:noreply, state}

  defp backspace(%{query: ""} = state), do: {{:change, %{action: :back}}, state}

  defp backspace(state),
    do: query(state, state.query |> String.graphemes() |> Enum.drop(-1) |> Enum.join())

  defp query(state, query) do
    state = %{state | query: query, cursor: 0}
    {{:change, %{query: query, cursor: 0}}, state}
  end

  defp move(state, cursor, step) do
    cursor = cursor |> max(0) |> min(max(state.count - 1, 0))
    state = %{state | cursor: land(state, cursor, step) || state.cursor}
    {{:change, %{query: state.query, cursor: state.cursor}}, state}
  end

  # The first row that can be chosen from `cursor`, looking the way the cursor
  # was moving, then back the other way when that runs off the end.
  defp land(state, cursor, step), do: walk(state, cursor, step) || walk(state, cursor, -step)

  defp walk(_state, cursor, _step) when cursor < 0, do: nil

  defp walk(state, cursor, step) do
    cond do
      cursor >= state.count -> nil
      MapSet.member?(state.skip, cursor) -> walk(state, cursor + step, step)
      true -> cursor
    end
  end

  @impl Breeze.Implicit
  def handle_modifiers(_type, _flags, _state), do: []

  @doc """
  The rows whose text, as `text` gives it, matches `query`, best first.

  A row matches when the query's characters appear in its text in order,
  ignoring case. Rows are ranked by how close together the matched characters
  are, with ties kept in the order given. An empty query keeps every row.
  """
  @spec filter([row], String.t(), (row -> String.t())) :: [row] when row: term()
  def filter(rows, "", _text), do: rows

  def filter(rows, query, text) do
    needle = query |> String.downcase() |> String.graphemes()

    rows
    |> Enum.with_index()
    |> Enum.flat_map(fn {row, index} ->
      case score(needle, row |> text.() |> String.downcase() |> String.graphemes()) do
        nil -> []
        score -> [{{score, index}, row}]
      end
    end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(&elem(&1, 1))
  end

  # The width of the tightest window holding the needle in order, or `nil`
  # when the needle is not a subsequence.
  defp score(needle, haystack) do
    haystack
    |> Enum.with_index()
    |> Enum.filter(fn {grapheme, _index} -> grapheme == hd(needle) end)
    |> Enum.flat_map(fn {_grapheme, start} ->
      case span(tl(needle), Enum.drop(haystack, start + 1), start + 1) do
        nil -> []
        stop -> [stop - start]
      end
    end)
    |> Enum.min(fn -> nil end)
  end

  defp span([], _haystack, stop), do: stop

  defp span([grapheme | rest], haystack, at) do
    case Enum.find_index(haystack, &(&1 == grapheme)) do
      nil -> nil
      index -> span(rest, Enum.drop(haystack, index + 1), at + index + 1)
    end
  end
end
