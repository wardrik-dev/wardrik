defmodule WardrikConsole.TableTest do
  use ExUnit.Case, async: true

  alias WardrikConsole.Table

  defp plain(data), do: data |> Owl.Data.untag() |> IO.chardata_to_string()

  defp lines(table, width), do: table |> Table.lines(width) |> Enum.map(&plain/1)

  defp sequences(%Owl.Tag{sequences: sequences, data: data}), do: sequences ++ sequences(data)
  defp sequences(list) when is_list(list), do: Enum.flat_map(list, &sequences/1)
  defp sequences(_other), do: []

  test "ragged rows are squared up with empty cells, and missing alignments are left" do
    table = Table.new(["a", "b", "c"], [["1"], ["2", "3", "4"]], [:right])

    assert table.rows == [["1", [], []], ["2", "3", "4"]]
    assert table.alignments == [:right, :left, :left]
  end

  test "alignment/1 reads the rule cell" do
    assert Table.alignment("---") == :left
    assert Table.alignment(":---") == :left
    assert Table.alignment("---:") == :right
    assert Table.alignment(":---:") == :center
  end

  test "lines/2 boxes the table, its columns at their natural width" do
    table = Table.new(["Name", "Price"], [["Breadtopia", "$18"], ["King Arthur", "$9.95"]])

    assert lines(table, 80) == [
             "╭─────────────┬───────╮",
             "│ Name        │ Price │",
             "├─────────────┼───────┤",
             "│ Breadtopia  │ $18   │",
             "│ King Arthur │ $9.95 │",
             "╰─────────────┴───────╯"
           ]
  end

  test "lines/2 wraps cells inside their column to keep the table in the width" do
    table = %{
      Table.new(["Rank", "Evidence"], [["1", "one two three four five six"], ["2", "short"]])
      | indent: 2
    }

    lines = lines(table, 24)

    assert Enum.all?(lines, &(String.length(&1) <= 24))
    assert Enum.all?(lines, &String.starts_with?(&1, "  "))
    assert "  │ 1    │ one two    │" in lines
    assert "  │      │ five six   │" in lines
  end

  test "lines/2 draws the header bright" do
    [_top, header | _rest] = Table.lines(Table.new(["Name"], [["x"]]), 80)

    assert :bright in sequences(header)
  end

  test "a table with no body rows is its header alone" do
    assert lines(Table.new(["a", "b"], []), 80) == ["a │ b"]
  end
end
