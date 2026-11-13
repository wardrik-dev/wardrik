defmodule WardrikDaemon.Console.Table do
  @moduledoc false

  @typedoc "How a column's cells are aligned, from the rule row's colons."
  @type alignment() :: :left | :right | :center

  @typedoc "A header row, body rows, one alignment per column, and how many columns to indent."
  @type t() :: %__MODULE__{
          header: [Owl.Data.t()],
          rows: [[Owl.Data.t()]],
          alignments: [alignment()],
          indent: non_neg_integer()
        }

  defstruct header: [], rows: [], alignments: [], indent: 0

  @doc "Returns a table. Short rows are padded with empty cells. Missing alignments are `:left`."
  @spec new([Owl.Data.t()], [[Owl.Data.t()]], [alignment()]) :: t()
  def new(header, rows, alignments \\ []) when is_list(header) and is_list(rows) do
    columns = Enum.max(Enum.map([header | rows], &length/1))

    %__MODULE__{
      header: square(header, columns),
      rows: Enum.map(rows, &square(&1, columns)),
      alignments: square(Enum.take(alignments, columns), columns, :left)
    }
  end

  defp square(cells, columns, filler \\ []) do
    cells ++ List.duplicate(filler, columns - length(cells))
  end

  @doc "Returns the alignment a rule cell asks for: `:---:` is `:center`, `---:` is `:right`, anything else `:left`."
  @spec alignment(String.t()) :: alignment()
  def alignment(rule) do
    case {String.starts_with?(rule, ":"), String.ends_with?(rule, ":")} do
      {true, true} -> :center
      {false, true} -> :right
      _other -> :left
    end
  end

  @doc "Returns the table as boxed lines no wider than `width`. Cells wrap inside their column."
  @spec lines(t(), pos_integer()) :: [Owl.Data.t()]
  def lines(%__MODULE__{rows: []} = table, _width) do
    [[indent(table), Owl.Data.tag(Enum.intersperse(table.header, " │ "), :bright)]]
  end

  def lines(%__MODULE__{} = table, width) when is_integer(width) and width > 0 do
    columns = Enum.to_list(0..(length(table.header) - 1))
    header = Map.new(Enum.zip(columns, table.header))

    table.rows
    |> Enum.map(&Map.new(Enum.zip(columns, &1)))
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
