defmodule Tars.TUI.Markdown do
  @moduledoc """
  Renders streamed markdown a line at a time.

  Text arrives a token at a time and has to reach the screen long before the
  document is finished, so this renders lines rather than documents. `push/2`
  takes whatever arrived and returns the lines that are now complete, keeping
  the rest:

      {lines, buffer} = Tars.TUI.Markdown.push(Tars.TUI.Markdown.new(), "# Title\\nsome ")
      {lines, buffer} = Tars.TUI.Markdown.push(buffer, "prose\\n")
      {lines, _buffer} = Tars.TUI.Markdown.flush(buffer)

  A fenced code block is the one construct that spans lines, so the buffer
  carries whether it is inside one. `tail/1` is the unfinished line, for a
  surface that wants to show what is arriving before it is a line.

  Nothing here wraps. Lines are written once and never redrawn, so the terminal
  soft-wraps them itself and a window resize reflows them correctly — which is
  not true of anything a renderer wrapped in advance.
  """

  @typedoc "Text not yet a complete line, and whether it sits inside a fence."
  @type t() :: %__MODULE__{pending: String.t(), fenced?: boolean()}

  defstruct pending: "", fenced?: false

  @faint [:faint, :light_black]

  @fence ~r/^\s*```(.*)$/
  @heading ~r/^(\#{1,6})\s+(.*)$/
  @rule ~r/^\s*(-{3,}|\*{3,}|_{3,})\s*$/
  @bullet ~r/^(\s*)[-*+]\s+(.*)$/
  @ordered ~r/^(\s*)(\d+)[.)]\s+(.*)$/
  @quoted ~r/^\s*>\s?(.*)$/
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
  @spec push(t(), String.t()) :: {[Owl.Data.t()], t()}
  def push(%__MODULE__{} = buffer, text) when is_binary(text) do
    case String.split(buffer.pending <> text, "\n") do
      [pending] ->
        {[], %{buffer | pending: pending}}

      lines ->
        {complete, [pending]} = Enum.split(lines, -1)
        {rendered, fenced?} = Enum.map_reduce(complete, buffer.fenced?, &line/2)

        {rendered, %{buffer | pending: pending, fenced?: fenced?}}
    end
  end

  @doc "Renders whatever is left, for the end of a stream."
  @spec flush(t()) :: {[Owl.Data.t()], t()}
  def flush(%__MODULE__{pending: ""} = buffer), do: {[], buffer}

  def flush(%__MODULE__{} = buffer) do
    {rendered, fenced?} = line(buffer.pending, buffer.fenced?)

    {[rendered], %{buffer | pending: "", fenced?: fenced?}}
  end

  @doc "The unfinished line, as plain text."
  @spec tail(t()) :: String.t()
  def tail(%__MODULE__{pending: pending}), do: pending

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
