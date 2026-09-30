defmodule WardrikTUI.Table do
  @moduledoc """
  Lays a `WardrikConsole.Table` out to a width when it is drawn.

  `WardrikConsole.Markdown` returns a table in place of a line.
  `WardrikTUI.Transcript` lays it out with `rows/2` at its current width, and
  again on a resize, so a table reflows the way prose does.

  Columns take their natural width when the table fits. When it does not, the
  widest column gives up columns first until a row fits, and each cell wraps
  inside its column, so a logical row is as tall as its tallest cell. Cells
  are padded to their column and aligned as the rule row says; the last column
  is never padded on the right.
  """

  alias WardrikTUI.Line
  alias WardrikTUI.Text

  @faint [:faint, :light_black]
  @separator " │ "
  @joint "─┼─"

  @doc "The table as terminal rows no wider than `width`."
  @spec rows(WardrikConsole.Table.t(), pos_integer()) :: [Line.t()]
  def rows(%WardrikConsole.Table{} = table, width) when is_integer(width) and width > 0 do
    header = Enum.map(table.header, &Line.segments(Text.tag(&1, :bright)))
    body = Enum.map(table.rows, fn row -> Enum.map(row, &Line.segments/1) end)
    widths = widths([header | body], available(width, table.indent, length(header)))
    columns = Enum.zip([widths, table.alignments, lasts(widths)])
    indent = spaces(table.indent)

    (logical(header, columns) ++ [rule(widths)] ++ Enum.flat_map(body, &logical(&1, columns)))
    |> Enum.map(&Line.trim_trailing(Line.segments(indent ++ &1)))
  end

  defp lasts(widths), do: List.duplicate(false, length(widths) - 1) ++ [true]

  # Room for cells once the indent and the separators are taken out, never
  # less than one column per column.
  defp available(width, indent, columns) do
    max(width - indent - String.length(@separator) * (columns - 1), columns)
  end

  defp widths(rows, available) do
    rows
    |> Enum.zip_with(fn column -> column |> Enum.map(&Line.width/1) |> Enum.max() end)
    |> fit(available)
  end

  defp fit(widths, available) do
    if Enum.sum(widths) <= available, do: widths, else: fit(shrink_widest(widths), available)
  end

  defp shrink_widest(widths) do
    {_width, index} = widths |> Enum.with_index() |> Enum.max_by(&elem(&1, 0))
    List.update_at(widths, index, &max(&1 - 1, 1))
  end

  # One logical row as as many terminal rows as its tallest cell needs. Each
  # cell wraps in its column and is padded to the tallest with empty rows;
  # zipping the columns together then yields one terminal row at a time.
  defp logical(cells, columns) do
    wrapped = Enum.zip_with(cells, columns, fn cell, {width, _, _} -> Line.wrap(cell, width) end)
    height = wrapped |> Enum.map(&length/1) |> Enum.max()

    wrapped
    |> Enum.map(&(&1 ++ List.duplicate([], height - length(&1))))
    |> Enum.zip_with(fn row ->
      row
      |> Enum.zip_with(columns, fn cell, {width, alignment, last?} ->
        cell(cell, width, alignment, last?)
      end)
      |> Enum.intersperse(separator())
      |> Enum.concat()
    end)
  end

  defp cell(row, width, alignment, last?) do
    gap = max(width - Line.width(row), 0)
    {left, right} = split(gap, alignment)

    spaces(left) ++ row ++ if(last?, do: [], else: spaces(right))
  end

  defp split(gap, :left), do: {0, gap}
  defp split(gap, :right), do: {gap, 0}
  defp split(gap, :center), do: {div(gap, 2), gap - div(gap, 2)}

  defp spaces(0), do: []
  defp spaces(n), do: [{String.duplicate(" ", n), %{}}]

  defp separator, do: Line.segments(Text.tag(@separator, @faint))

  defp rule(widths) do
    widths
    |> Enum.map(&String.duplicate("─", &1))
    |> Enum.intersperse(@joint)
    |> Text.tag(@faint)
    |> Line.segments()
  end
end
