defmodule WardrikTUI.Transcript do
  @moduledoc """
  The append-only transcript, kept as terminal rows.

  Lines arrive as `WardrikTUI.Text` and are wrapped to the transcript's width as they
  are appended. A `WardrikConsole.Table` arrives as one line and is laid out to the
  width the same way. `source/1` presents the rows to Breeze as a lazy
  `BackBreeze.VirtualText`, which fetches only the rows it draws, under a key
  naming this transcript, its version and its width, so the renderer never
  reuses rows of another transcript at the same version. `rewrap/2` rebuilds
  the rows for a new width.

  A transcript drawn over other content is made with `pad?: true`: each row is
  filled to the width with faint spaces, which the compositor keeps where it
  would let an unstyled gap show what lies beneath.
  """

  alias BackBreeze.VirtualText
  alias WardrikConsole.Table
  alias WardrikTUI.Line
  alias WardrikTUI.Text

  @type t() :: %__MODULE__{
          width: pos_integer(),
          lines: [Line.t() | Table.t()],
          rows: :array.array(),
          version: non_neg_integer(),
          ref: reference(),
          pad?: boolean()
        }

  defstruct width: 100, lines: [], rows: nil, version: 0, ref: nil, pad?: false

  @doc "An empty transcript wrapped at `width` columns. Option `:pad?` fills each row."
  @spec new(pos_integer(), keyword()) :: t()
  def new(width, opts \\ []) when is_integer(width) and width > 0 do
    %__MODULE__{
      width: width,
      rows: :array.new(),
      ref: make_ref(),
      pad?: Keyword.get(opts, :pad?, false)
    }
  end

  @doc """
  Appends one line of `WardrikTUI.Text`. Data containing newlines is appended as
  several lines.
  """
  @spec append(t(), Text.t() | Table.t()) :: t()
  def append(%__MODULE__{} = transcript, %Table{} = table), do: append_line(transcript, table)

  def append(%__MODULE__{} = transcript, data) do
    data
    |> Line.segments()
    |> Line.lines()
    |> Enum.reduce(transcript, &append_line(&2, &1))
  end

  @doc "Appends each of `lines` in order."
  @spec append_all(t(), [Text.t() | Table.t()]) :: t()
  def append_all(%__MODULE__{} = transcript, lines) when is_list(lines) do
    Enum.reduce(lines, transcript, &append(&2, &1))
  end

  defp append_line(transcript, line) do
    rows =
      line
      |> layout(transcript.width)
      |> Enum.map(&fill(&1, transcript))
      |> Enum.reduce(transcript.rows, fn row, rows -> :array.set(:array.size(rows), row, rows) end)

    %{transcript | lines: [line | transcript.lines], rows: rows, version: transcript.version + 1}
  end

  defp layout(%Table{} = table, width), do: WardrikTUI.Table.rows(table, width)
  defp layout(line, width), do: Line.wrap(line, width)

  defp fill(row, %__MODULE__{pad?: false}), do: row

  defp fill(row, %__MODULE__{width: width}) do
    case width - Line.width(row) do
      short when short > 0 -> row ++ Line.segments(Text.tag(String.duplicate(" ", short), :faint))
      _fits -> row
    end
  end

  @doc "Wraps every line again at `width`. A no-op when the width is unchanged."
  @spec rewrap(t(), pos_integer()) :: t()
  def rewrap(%__MODULE__{width: width} = transcript, width), do: transcript

  def rewrap(%__MODULE__{} = transcript, width) when is_integer(width) and width > 0 do
    transcript.lines
    |> Enum.reverse()
    |> Enum.reduce(
      %{new(width, pad?: transcript.pad?) | version: transcript.version},
      &append_line(&2, &1)
    )
  end

  @doc "How many terminal rows the transcript occupies."
  @spec rows(t()) :: non_neg_integer()
  def rows(%__MODULE__{rows: rows}), do: :array.size(rows)

  @doc "The rows in order, as plain text."
  @spec to_list(t()) :: [String.t()]
  def to_list(%__MODULE__{rows: rows}), do: rows |> :array.to_list() |> Enum.map(&Line.text/1)

  @doc """
  The rows whose text contains `query`, ignoring case, as `{row, text}` in
  order. An empty query matches nothing.
  """
  @spec find(t(), String.t()) :: [{non_neg_integer(), String.t()}]
  def find(%__MODULE__{}, ""), do: []

  def find(%__MODULE__{rows: rows}, query) when is_binary(query) do
    needle = String.downcase(query)

    :array.foldr(
      fn index, row, found ->
        text = Line.text(row)

        if String.contains?(String.downcase(text), needle),
          do: [{index, text} | found],
          else: found
      end,
      [],
      rows
    )
  end

  @doc """
  The transcript as a lazy virtual text for a Breeze `scroll` block.

  Breeze only calls `slice_fn` for the rows it is about to draw.

  `tail` are rows drawn after the transcript's own and held by nobody: text
  arriving that is not yet a line. They are not part of the transcript, so they
  do not count towards `rows/1`, are not searched, and are replaced whole on
  every call.
  """
  @spec source(t(), [Line.t()]) :: struct()
  def source(%__MODULE__{rows: rows, version: version, width: width, ref: ref}, tail \\ []) do
    count = :array.size(rows)
    total = count + length(tail)

    VirtualText.lazy(
      cache_key: {__MODULE__, ref, version, width, tail},
      cache?: false,
      intrinsic_width: 1,
      line_count_fn: fn _width -> total end,
      slice_fn: fn start, wanted, _width -> slice(rows, count, tail, start, wanted) end
    )
  end

  defp slice(_rows, _count, _tail, _start, wanted) when wanted <= 0, do: []

  defp slice(rows, count, tail, start, wanted) do
    taken = for i <- start..(min(start + wanted, count) - 1)//1, do: :array.get(i, rows)
    taken ++ Enum.slice(tail, max(start - count, 0), wanted - length(taken))
  end
end
