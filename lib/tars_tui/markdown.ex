defmodule TarsTUI.Markdown do
  @moduledoc """
  Renders streamed markdown a line at a time.

  Text arrives a token at a time and has to reach the screen long before the
  document is finished, so this renders lines rather than documents. `push/2`
  takes whatever arrived and returns the lines that are now complete, keeping
  the rest:

      {lines, buffer} = TarsTUI.Markdown.push(TarsTUI.Markdown.new(), "# Title\\nsome ")
      {lines, buffer} = TarsTUI.Markdown.push(buffer, "prose\\n")
      {lines, _buffer} = TarsTUI.Markdown.flush(buffer)

  Two constructs span lines. A fenced code block, so the buffer carries whether
  it is inside one. A table, whose rows are held back until the line after it
  arrives and then rendered together with their columns aligned. `tail/1` is
  the unfinished line, for a surface that wants to show what is arriving
  before it is a line.

  Nothing here wraps. Lines are written once and never redrawn, so the terminal
  soft-wraps them itself and a window resize reflows them correctly — which is
  not true of anything a renderer wrapped in advance.
  """

  @typedoc "Text not yet a complete line, whether it sits inside a fence, and the table rows held back."
  @type t() :: %__MODULE__{pending: String.t(), fenced?: boolean(), table: [String.t()]}

  alias TarsTUI.Text

  defstruct pending: "", fenced?: false, table: []

  @faint [:faint, :light_black]

  @fence ~r/^\s*```(.*)$/
  @heading ~r/^(\#{1,6})\s+(.*)$/
  @rule ~r/^\s*(-{3,}|\*{3,}|_{3,})\s*$/
  @bullet ~r/^(\s*)[-*+]\s+(.*)$/
  @ordered ~r/^(\s*)(\d+)[.)]\s+(.*)$/
  @quoted ~r/^\s*>\s?(.*)$/
  @table_row ~r/^\s*\|.*\|\s*$/
  # A marker has to hug its content, or `2 * 3 * 4` reads as emphasis.
  @code "`[^`]+`"
  @bold "\\*\\*(?!\\s)(?:[^*]*[^\\s*])?\\*\\*"
  @emphasis "\\*(?!\\s)(?:[^*]*[^\\s*])?\\*"
  @underscored "_(?!\\s)(?:[^_]*[^\\s_])?_"
  @link "\\[[^\\]]*\\]\\([^)]+\\)"

  @inline ~r/(#{@code}|#{@bold}|#{@emphasis}|#{@underscored}|#{@link})/

  @doc "An empty buffer."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Adds `text` and returns the lines it completed.

  Lines come back rendered, in order, without their newlines.
  """
  @spec push(t(), String.t()) :: {[Text.t()], t()}
  def push(%__MODULE__{} = buffer, text) when is_binary(text) do
    case String.split(buffer.pending <> text, "\n") do
      [pending] ->
        {[], %{buffer | pending: pending}}

      lines ->
        {complete, [pending]} = Enum.split(lines, -1)
        {rendered, buffer} = Enum.flat_map_reduce(complete, buffer, &absorb/2)

        {rendered, %{buffer | pending: pending}}
    end
  end

  @doc "Renders whatever is left, for the end of a stream."
  @spec flush(t()) :: {[Text.t()], t()}
  def flush(%__MODULE__{pending: "", table: []} = buffer), do: {[], buffer}

  def flush(%__MODULE__{pending: ""} = buffer) do
    {table(buffer.table), %{buffer | table: []}}
  end

  def flush(%__MODULE__{} = buffer) do
    {rendered, buffer} = absorb(buffer.pending, %{buffer | pending: ""})
    {rest, buffer} = flush(buffer)

    {rendered ++ rest, buffer}
  end

  # One complete line: rendered now, or held back as a table row.
  defp absorb(text, %{fenced?: false, table: table} = buffer) when table != [] do
    if Regex.match?(@table_row, text) do
      {[], %{buffer | table: [text | table]}}
    else
      {rendered, buffer} = absorb(text, %{buffer | table: []})
      {table(table) ++ rendered, buffer}
    end
  end

  defp absorb(text, %{fenced?: false} = buffer) do
    if Regex.match?(@table_row, text) do
      {[], %{buffer | table: [text]}}
    else
      {rendered, fenced?} = line(text, false)
      {[rendered], %{buffer | fenced?: fenced?}}
    end
  end

  defp absorb(text, %{fenced?: true} = buffer) do
    {rendered, fenced?} = line(text, true)
    {[rendered], %{buffer | fenced?: fenced?}}
  end

  @doc "The unfinished line, as plain text."
  @spec tail(t()) :: String.t()
  def tail(%__MODULE__{pending: pending}), do: pending

  @doc "Renders one complete line of markdown, outside any fence."
  @spec line(String.t()) :: Text.t()
  def line(text) when is_binary(text), do: text |> line(false) |> elem(0)

  defp line(text, true) do
    if Regex.match?(@fence, text), do: {[], false}, else: {code(text), true}
  end

  defp line(text, false) do
    if Regex.match?(@fence, text), do: {fence(text), true}, else: {block(text), false}
  end

  defp fence(text) do
    case Regex.run(@fence, text) do
      [_whole, ""] -> []
      [_whole, language] -> Text.tag(String.trim(language), @faint)
    end
  end

  defp code(text), do: ["  ", Text.tag(text, :cyan)]

  defp block(text) do
    cond do
      match = Regex.run(@heading, text) -> heading(match)
      Regex.match?(@rule, text) -> Text.tag("───────", @faint)
      match = Regex.run(@bullet, text) -> bullet(match)
      match = Regex.run(@ordered, text) -> ordered(match)
      match = Regex.run(@quoted, text) -> quoted(match)
      true -> inline(text)
    end
  end

  defp heading([_whole, hashes, text]) do
    Text.tag(inline(text), heading_tag(String.length(hashes)))
  end

  defp heading_tag(1), do: [:bright, :cyan]
  defp heading_tag(_level), do: :cyan

  defp bullet([_whole, indent, text]) do
    [indent, Text.tag("• ", :cyan), inline(text)]
  end

  defp ordered([_whole, indent, number, text]) do
    [indent, Text.tag("#{number}. ", :cyan), inline(text)]
  end

  defp quoted([_whole, text]) do
    [Text.tag("│ ", :cyan), Text.tag(inline(text), @faint)]
  end

  # Rows held back in reverse order. The first row is the header when a rule
  # follows it; rule rows are dropped and drawn as one line under the header.
  defp table([]), do: []

  defp table(rows) do
    rows = rows |> Enum.reverse() |> Enum.map(&cells/1)
    {header, body} = split_header(rows)
    body = Enum.reject(body, &rule?/1)
    columns = Enum.max(Enum.map([header | body], &length/1))
    rows = Enum.map([header | body], &(&1 ++ List.duplicate([], columns - length(&1))))

    widths =
      Enum.zip_with(rows, fn column -> column |> Enum.map(&Text.length/1) |> Enum.max() end)

    [header | body] = rows

    [row(header, widths, :bright), rule(widths)] ++ Enum.map(body, &row(&1, widths, nil))
  end

  defp cells(text) do
    text
    |> String.trim()
    |> String.trim_leading("|")
    |> String.trim_trailing("|")
    |> String.split("|")
    |> Enum.map(&inline(String.trim(&1)))
  end

  defp split_header([header, second | rest]) do
    if rule?(second), do: {header, rest}, else: {header, [second | rest]}
  end

  defp split_header([header]), do: {header, []}

  defp rule?(cells), do: Enum.all?(cells, &Regex.match?(~r/^:?-{2,}:?$/, Text.plain(&1)))

  defp row(cells, widths, emphasis) do
    [cells, widths]
    |> Enum.zip_with(fn [cell, width] -> pad(cell, width, emphasis) end)
    |> Enum.intersperse(Text.tag(" │ ", @faint))
  end

  defp pad(cell, width, emphasis) do
    filler = String.duplicate(" ", max(width - Text.length(cell), 0))
    if emphasis, do: [Text.tag(cell, emphasis), filler], else: [cell, filler]
  end

  defp rule(widths) do
    widths
    |> Enum.map(&String.duplicate("─", &1))
    |> Enum.intersperse("─┼─")
    |> then(&Text.tag(&1, @faint))
  end

  defp inline(text) do
    @inline
    |> Regex.split(text, include_captures: true, trim: true)
    |> Enum.map(&fragment/1)
  end

  defp fragment(fragment) do
    cond do
      match = Regex.run(~r/^`(.+)`$/s, fragment) -> tagged(match, :cyan)
      match = Regex.run(~r/^\*\*(.+)\*\*$/s, fragment) -> tagged(match, :bright)
      match = Regex.run(~r/^[*_](.+)[*_]$/s, fragment) -> tagged(match, :italic)
      match = Regex.run(~r/^\[(.*)\]\((.+)\)$/s, fragment) -> link(match)
      true -> fragment
    end
  end

  defp tagged([_whole, text], sequence), do: Text.tag(text, sequence)

  defp link([_whole, "", url]), do: link([nil, url, url])
  defp link([_whole, text, url]), do: Text.tag(text, [{:hyperlink, url}, :underline])
end
