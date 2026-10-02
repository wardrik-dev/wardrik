defmodule WardrikTUI.Text do
  @moduledoc """
  Styled text, as the renderers build it.

  Text is a binary, a `{text, style}` segment, a tag wrapping text in ANSI
  sequence names such as `:cyan`, `:bright` or `[:faint, :light_black]`, or
  a list of any of these. A tag is an `Owl.Tag`, so the lines
  `WardrikConsole.Markdown` renders are text here too.
  `WardrikTUI.Line.segments/1` flattens it for layout; `to_ansi/1` renders it
  for a single-row box.
  """

  import Kernel, except: [length: 1]

  alias WardrikTUI.Line

  @typedoc "A tag: text drawn with its sequences."
  @type tag() :: Owl.Tag.t(t())

  @typedoc "Styled text."
  @type t() :: binary() | Line.segment() | tag() | [t()]

  @doc "An elapsed duration in milliseconds or fractional seconds."
  @spec duration(non_neg_integer()) :: String.t()
  def duration(ms) when ms < 1_000, do: "#{ms}ms"
  def duration(ms), do: "#{Float.round(ms / 1_000, 1)}s"

  @doc "Wraps `data` in one sequence or a list of them."
  @spec tag(t(), Owl.Data.sequence() | [Owl.Data.sequence()]) :: tag()
  def tag(data, sequences), do: Owl.Data.tag(data, sequences)

  @doc "The text without its styles."
  @spec plain(t()) :: String.t()
  def plain(data), do: data |> Line.segments() |> Line.text()

  @doc "How many columns the text occupies."
  @spec length(t()) :: non_neg_integer()
  def length(data), do: data |> Line.segments() |> Line.width()

  @doc "The text clipped to `width` columns, ending in an ellipsis when it was longer."
  @spec truncate(t(), pos_integer()) :: t()
  def truncate(data, width) when is_integer(width) and width > 0 do
    segments = Line.segments(data)

    if Line.width(segments) <= width do
      data
    else
      chars =
        for {text, style} <- segments, grapheme <- String.graphemes(text), do: {grapheme, style}

      kept = take(chars, width - 1, 0, [])
      Line.segments(Enum.reverse([{"…", %{}} | kept]))
    end
  end

  defp take([{grapheme, _style} = char | rest], room, used, acc) do
    used = used + BackBreeze.Ucwidth.width(grapheme)
    if used > room, do: acc, else: take(rest, room, used, [char | acc])
  end

  defp take([], _room, _used, acc), do: acc

  @doc """
  The text with its styles as ANSI escape sequences, opened by `Termite.Style`.

  Each run is closed by resetting only what it set, so the background of the
  box it is drawn in carries on after it.
  """
  @spec to_ansi(t()) :: String.t()
  def to_ansi(data) do
    data
    |> Line.segments()
    |> Enum.map(fn {text, style} -> ansi(text, style) end)
    |> IO.iodata_to_binary()
  end

  defp ansi(text, style) do
    case close(style) do
      [] ->
        text

      codes ->
        [Termite.Style.open_code(termite(style)), text, "\e[", Enum.intersperse(codes, ";"), "m"]
    end
  end

  defp close(style) do
    Enum.flat_map(style, fn
      {:bold, true} -> ["22"]
      {:italic, true} -> ["23"]
      {:foreground_color, _colour} -> ["39"]
      _other -> []
    end)
  end

  defp termite(style) do
    Enum.reduce(style, %Termite.Style{}, fn
      {:bold, true}, acc -> Termite.Style.bold(acc)
      {:italic, true}, acc -> Termite.Style.italic(acc)
      {:foreground_color, colour}, acc -> Termite.Style.foreground(acc, colour)
      _other, acc -> acc
    end)
  end
end
