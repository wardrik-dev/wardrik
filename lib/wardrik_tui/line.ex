defmodule WardrikTUI.Line do
  @moduledoc """
  Styled text as a list of `{text, style}` segments.

  `segments/1` flattens `WardrikTUI.Text` into segments, `lines/1` splits segments at
  newlines, and `wrap/2` breaks a line into rows of at most `width` columns,
  on spaces where there are any, keeping each segment's style.

  A style holds the subset Breeze applies per segment: `:bold`, `:italic` and
  `:foreground_color` as an ANSI colour index. Faint text is bright black.
  """

  alias BackBreeze.Ucwidth
  alias WardrikTUI.Text

  @typedoc "Breeze's per-segment style."
  @type style() :: %{
          optional(:bold) => true,
          optional(:italic) => true,
          optional(:foreground_color) => 0..15
        }

  @typedoc "One run of text and how it is drawn."
  @type segment() :: {String.t(), style()}

  @typedoc "One line, or one wrapped row, of a transcript."
  @type t() :: [segment()]

  @colours %{
    black: 0,
    red: 1,
    green: 2,
    yellow: 3,
    blue: 4,
    magenta: 5,
    cyan: 6,
    white: 7,
    light_black: 8,
    light_red: 9,
    light_green: 10,
    light_yellow: 11,
    light_blue: 12,
    light_magenta: 13,
    light_cyan: 14,
    light_white: 15
  }

  @doc "Flattens `WardrikTUI.Text` into segments, merging neighbours that share a style."
  @spec segments(Text.t() | t()) :: t()
  def segments(data), do: data |> flatten(%{}) |> merge()

  defp flatten(%Text{sequences: sequences, data: data}, style) do
    flatten(data, Enum.reduce(List.wrap(sequences), style, &apply_sequence/2))
  end

  defp flatten(list, style) when is_list(list), do: Enum.flat_map(list, &flatten(&1, style))
  defp flatten({text, %{} = style}, _style) when is_binary(text), do: [{text, style}]
  defp flatten("", _style), do: []
  defp flatten(text, style) when is_binary(text), do: [{text, style}]
  defp flatten(other, style), do: [{to_string(other), style}]

  defp apply_sequence(:bright, style), do: Map.put(style, :bold, true)
  defp apply_sequence(:italic, style), do: Map.put(style, :italic, true)
  defp apply_sequence(:faint, style), do: Map.put(style, :foreground_color, 8)
  defp apply_sequence(:reset, _style), do: %{}

  defp apply_sequence(colour, style) when is_map_key(@colours, colour) do
    Map.put(style, :foreground_color, Map.fetch!(@colours, colour))
  end

  defp apply_sequence(_other, style), do: style

  @doc "Splits segments into lines at newlines. A trailing newline ends the last line rather than starting an empty one."
  @spec lines(t()) :: [t()]
  def lines(segments) do
    segments
    |> Enum.reduce([[]], fn {text, style}, [current | done] ->
      case String.split(text, "\n") do
        [only] ->
          [[{only, style} | current] | done]

        [first | rest] ->
          {last, middle} = List.pop_at(rest, -1)
          started = Enum.map(middle, &[{&1, style}])
          [[{last, style}] | Enum.reverse(started, [[{first, style} | current] | done])]
      end
    end)
    |> Enum.reverse()
    |> Enum.map(&(&1 |> Enum.reverse() |> merge()))
    |> drop_trailing_empty()
  end

  defp drop_trailing_empty([_only] = lines), do: lines

  defp drop_trailing_empty(lines) do
    case List.last(lines) do
      [] -> Enum.drop(lines, -1)
      _content -> lines
    end
  end

  @doc """
  Breaks one line into rows no wider than `width`, on spaces where possible.

  Rows after the first hang under the line's leading whitespace and bullet,
  so a wrapped list item or tree entry keeps its shape. A line that opens with
  a bar, as a block quote or a reasoning line does, repeats the bar on every
  row instead. Trailing spaces are dropped from the line and from each row.
  """
  @spec wrap(t(), pos_integer()) :: [t()]
  def wrap(segments, width) when is_integer(width) and width > 0 do
    chars =
      for {text, style} <- segments, grapheme <- String.graphemes(text), do: {grapheme, style}

    chars = trim_chars(chars)
    {hang, prefix} = hanging(text(segments), chars, width)
    {first, rest} = take(chars, width)

    continuation =
      rest
      |> rows(width - hang, [])
      |> Enum.map(&trim_chars/1)
      |> Enum.reject(&(&1 == []))
      |> Enum.map(&(prefix ++ &1))

    Enum.map([trim_chars(first) | continuation], &merge/1)
  end

  @doc "The line without its trailing spaces."
  @spec trim_trailing(t()) :: t()
  def trim_trailing(segments) do
    segments |> Enum.reverse() |> trim_reversed() |> Enum.reverse()
  end

  defp trim_reversed([{text, style} | rest]) do
    case String.trim_trailing(text, " ") do
      "" -> trim_reversed(rest)
      trimmed -> [{trimmed, style} | rest]
    end
  end

  defp trim_reversed([]), do: []

  @bar ~r/^\s*[│┊]\s/u
  @bullet ~r/^(\s*)(?:[⏺•·✓✗⇢›»■-]\s+|\d+[.)]\s+)?/u

  # The columns continuation rows hang by, and what fills them: the bar the
  # line opened with, or spaces under a bullet.
  defp hanging(text, chars, width) do
    {hang, bar?} =
      case Regex.run(@bar, text) do
        [match] -> {String.length(match), true}
        nil -> {text |> then(&Regex.run(@bullet, &1)) |> hd() |> String.length(), false}
      end

    cond do
      hang >= width - 8 -> {0, []}
      bar? -> {hang, Enum.take(chars, hang)}
      true -> {hang, for(_ <- 1..hang//1, do: {" ", %{}})}
    end
  end

  defp trim_chars(chars) do
    chars
    |> Enum.reverse()
    |> Enum.drop_while(fn {grapheme, _style} -> grapheme == " " end)
    |> Enum.reverse()
  end

  defp rows([], _width, acc), do: Enum.reverse(acc)

  defp rows(chars, width, acc) do
    case take(chars, width) do
      {row, []} -> Enum.reverse([row | acc])
      {row, rest} -> rows(rest, width, [row | acc])
    end
  end

  # Takes up to `width` columns. Past the width, the row ends at the last
  # space if there was one, which is dropped, and otherwise mid-word.
  defp take(chars, width) do
    {fitting, rest} = fit(chars, width, [], 0)

    case {rest, Enum.find_index(fitting, fn {grapheme, _style} -> grapheme == " " end)} do
      {[], _space} ->
        {Enum.reverse(fitting), []}

      {[{" ", _style} | more], _space} ->
        {Enum.reverse(fitting), more}

      {_more, nil} ->
        {Enum.reverse(fitting), rest}

      {_more, space} ->
        {fitting |> Enum.drop(space + 1) |> Enum.reverse(),
         Enum.reverse(Enum.take(fitting, space), rest)}
    end
  end

  defp fit([], _width, taken, _columns), do: {taken, []}

  defp fit([{grapheme, _style} = char | rest] = chars, width, taken, columns) do
    columns = columns + Ucwidth.width(grapheme)
    if columns > width, do: {taken, chars}, else: fit(rest, width, [char | taken], columns)
  end

  @doc "The text of a line or row, without its styles."
  @spec text(t()) :: String.t()
  def text(segments), do: Enum.map_join(segments, &elem(&1, 0))

  @doc "How many columns a line or row occupies."
  @spec width(t()) :: non_neg_integer()
  def width(segments) do
    segments |> text() |> String.graphemes() |> Enum.reduce(0, &(Ucwidth.width(&1) + &2))
  end

  defp merge(segments) do
    segments
    |> Enum.reject(fn {text, _style} -> text == "" end)
    |> Enum.chunk_by(&elem(&1, 1))
    |> Enum.map(fn [{_text, style} | _rest] = run -> {text(run), style} end)
  end
end
