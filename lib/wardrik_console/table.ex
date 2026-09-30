defmodule WardrikConsole.Table do
  @moduledoc """
  A markdown table: its header, its body rows, and how each column's cells
  sit in it.

  `WardrikConsole.Markdown` builds one from the rows it held back and returns
  it in place of a line. Laying it out is left to whoever draws it, at the
  width it has then: `lines/2` does, for a terminal written a line at a time.
  """

  @typedoc "How a column's cells sit in it, from the rule row's colons."
  @type alignment() :: :left | :right | :center

  @typedoc "A header row, body rows, one alignment per column, and columns of indent."
  @type t() :: %__MODULE__{
          header: [Owl.Data.t()],
          rows: [[Owl.Data.t()]],
          alignments: [alignment()],
          indent: non_neg_integer()
        }

  defstruct header: [], rows: [], alignments: [], indent: 0

  @doc """
  A table from its header, its body rows and its alignments.

  Rows shorter than the widest are squared up with empty cells; missing
  alignments are `:left`.
  """
  @spec new([Owl.Data.t()], [[Owl.Data.t()]], [alignment()]) :: t()
  def new(header, rows, alignments \\ []) when is_list(header) and is_list(rows) do
    columns = [header | rows] |> Enum.map(&length/1) |> Enum.max()

    %__MODULE__{
      header: square(header, columns),
      rows: Enum.map(rows, &square(&1, columns)),
      alignments: alignments |> Enum.take(columns) |> square(columns, :left)
    }
  end

  defp square(cells, columns, filler \\ []) do
    cells ++ List.duplicate(filler, columns - length(cells))
  end

  @doc "The alignment a rule cell such as `:---:` asks for."
  @spec alignment(String.t()) :: alignment()
  def alignment(rule) do
    case {String.starts_with?(rule, ":"), String.ends_with?(rule, ":")} do
      {true, true} -> :center
      {false, true} -> :right
      _other -> :left
    end
  end

  @doc """
  The table as lines no wider than `width`, for a terminal that is written to
  and never redrawn.

  The table is boxed, with its header bright. Columns take their natural width
  where they fit and each cell wraps inside its column where they do not, every
  cell sitting at the left. A table with no body rows is its header alone.
  """
  @spec lines(t(), pos_integer()) :: [Owl.Data.t()]
  def lines(%__MODULE__{rows: []} = table, _width) do
    [[indent(table), Owl.Data.tag(Enum.intersperse(table.header, " │ "), :bright)]]
  end

  def lines(%__MODULE__{} = table, width) when is_integer(width) and width > 0 do
    columns = Enum.to_list(0..(length(table.header) - 1))
    header = columns |> Enum.zip(table.header) |> Map.new()

    table.rows
    |> Enum.map(&(columns |> Enum.zip(&1) |> Map.new()))
    |> Owl.Table.new(
      render_cell: [header: &Owl.Data.tag(Map.fetch!(header, &1), :bright), body: & &1],
      border_style: :solid_rounded,
      padding_x: 1,
      word_wrap: :normal,
      max_width: max(width - table.indent, 2)
    )
    |> Owl.Data.lines()
    |> Enum.map(&[indent(table), &1])
  end

  defp indent(%__MODULE__{indent: indent}), do: String.duplicate(" ", indent)
end
