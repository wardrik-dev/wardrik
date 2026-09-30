defmodule WardrikConsole.Markdown do
  @moduledoc """
  Renders streamed markdown a line at a time.

  Text arrives a token at a time and has to reach the screen long before the
  document is finished, so this renders lines rather than documents. `push/2`
  takes whatever arrived and returns the lines that are now complete, keeping
  the rest:

      {lines, buffer} = WardrikConsole.Markdown.push(WardrikConsole.Markdown.new(), "# Title\\nsome ")
      {lines, buffer} = WardrikConsole.Markdown.push(buffer, "prose\\n")
      {lines, _buffer} = WardrikConsole.Markdown.flush(buffer)

  A line is `Owl.Data`. Two constructs span lines. A fenced code block, so the
  buffer carries whether it is inside one. A table, whose rows are held back
  until the line after it arrives and then returned together as one
  `WardrikConsole.Table`, which whoever draws it lays out at its own width.
  `tail/1` is the unfinished line, for a surface that wants to show what is
  arriving before it is a line.

  Nothing here wraps. Whoever draws a line wraps it at its own width, so a
  screen that is resized can wrap it again.
  """

  alias WardrikConsole.Table

  @typedoc "Text not yet a complete line, whether it sits inside a fence, and the table rows held back."
  @type t() :: %__MODULE__{pending: String.t(), fenced?: boolean(), table: [String.t()]}

  @typedoc "What one complete line renders to: styled text, or a table."
  @type line() :: Owl.Data.t() | Table.t()

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
  @spec push(t(), String.t()) :: {[line()], t()}
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
  @spec flush(t()) :: {[line()], t()}
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

  @doc """
  The contents of each fenced code block in `text`, in order, without the
  fences or a trailing newline.
  """
  @spec code_blocks(String.t()) :: [String.t()]
  def code_blocks(text) when is_binary(text) do
    ~r/^[ \t]*(`{3,}|~{3,})[^\n]*\n(.*?)\n[ \t]*\1[ \t]*$/ms
    |> Regex.scan(text, capture: :all_but_first)
    |> Enum.map(fn [_fence, body] -> body end)
  end

  @doc """
  The unfinished line, rendered as it would be if the stream ended here, or
  `nil` when nothing is pending.

  What comes back is provisional: the same text is rendered again, as a line,
  once its newline arrives.
  """
  @spec tail(t()) :: Owl.Data.t() | nil
  def tail(%__MODULE__{pending: ""}), do: nil

  def tail(%__MODULE__{pending: pending, fenced?: fenced?}),
    do: pending |> line(fenced?) |> elem(0)

  @doc "Renders one complete line of markdown, outside any fence."
  @spec line(String.t()) :: Owl.Data.t()
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
      [_whole, language] -> Owl.Data.tag(String.trim(language), @faint)
    end
  end

  defp code(text), do: ["  ", Owl.Data.tag(text, :cyan)]

  defp block(text) do
    cond do
      match = Regex.run(@heading, text) -> heading(match)
      Regex.match?(@rule, text) -> Owl.Data.tag("───────", @faint)
      match = Regex.run(@bullet, text) -> bullet(match)
      match = Regex.run(@ordered, text) -> ordered(match)
      match = Regex.run(@quoted, text) -> quoted(match)
      true -> inline(text)
    end
  end

  defp heading([_whole, hashes, text]) do
    Owl.Data.tag(inline(text), heading_tag(String.length(hashes)))
  end

  defp heading_tag(1), do: [:bright, :cyan]
  defp heading_tag(_level), do: :cyan

  defp bullet([_whole, indent, text]) do
    [indent, Owl.Data.tag("• ", :cyan), inline(text)]
  end

  defp ordered([_whole, indent, number, text]) do
    [indent, Owl.Data.tag("#{number}. ", :cyan), inline(text)]
  end

  defp quoted([_whole, text]) do
    [Owl.Data.tag("│ ", :cyan), Owl.Data.tag(inline(text), @faint)]
  end

  # Rows held back in reverse order. The first row is the header; a rule row
  # after it sets the column alignments, and any other rule row is dropped.
  defp table([]), do: []

  defp table(rows) do
    rows = rows |> Enum.reverse() |> Enum.map(&cells/1)
    {header, alignments, body} = split_header(rows)

    [Table.new(header, Enum.reject(body, &rule?/1), alignments)]
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
    if rule?(second) do
      {header, Enum.map(second, &Table.alignment(plain(&1))), rest}
    else
      {header, [], [second | rest]}
    end
  end

  defp split_header([header]), do: {header, [], []}

  defp rule?(cells), do: Enum.all?(cells, &Regex.match?(~r/^:?-{2,}:?$/, plain(&1)))

  defp plain(cell), do: cell |> Owl.Data.untag() |> IO.chardata_to_string()

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

  defp tagged([_whole, text], sequence), do: Owl.Data.tag(text, sequence)

  defp link([_whole, "", url]), do: link([nil, url, url])
  defp link([_whole, text, url]), do: Owl.Data.tag(text, [{:hyperlink, url}, :underline])
end
