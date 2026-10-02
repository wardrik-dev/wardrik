defmodule WardrikTUI.TableTest do
  use ExUnit.Case, async: true

  alias WardrikTUI.Line
  alias WardrikTUI.Table
  alias WardrikTUI.Text

  # The table Markdown hands over, which this module lays out.
  defp table(header, rows, alignments \\ []),
    do: WardrikConsole.Table.new(header, rows, alignments)

  defp rows(table, width), do: table |> Table.rows(width) |> Enum.map(&Line.text/1)

  test "columns take their natural width when the table fits" do
    table = table(["Name", "Price"], [["Breadtopia", "$18"], ["King Arthur", "$9.95"]])

    assert rows(table, 80) == [
             "Name        │ Price",
             "────────────┼──────",
             "Breadtopia  │ $18",
             "King Arthur │ $9.95"
           ]
  end

  test "the last column is never padded, so no row ends in spaces" do
    table = table(["a", "b"], [["c", "dd"]])

    assert rows(table, 80) == ["a │ b", "──┼───", "c │ dd"]
  end

  test "the widest column gives way and its cells wrap inside it" do
    table =
      table(["Rank", "Evidence"], [
        ["1", "one two three four five six"],
        ["2", "short"]
      ])

    assert rows(table, 22) == [
             "Rank │ Evidence",
             "─────┼────────────────",
             "1    │ one two three",
             "     │ four five six",
             "2    │ short"
           ]
  end

  test "a table wider than the screen at every column still fits it" do
    table = table(["alpha beta", "gamma delta"], [["epsilon zeta", "eta theta"]])

    for row <- Table.rows(table, 12), do: assert(Line.width(row) <= 12)
  end

  test "cells are right- and centre-aligned when the rule says so" do
    table =
      table(["n", "mid", "name"], [["1", "a", "x"], ["10", "bbb", "y"]], [
        :right,
        :center,
        :left
      ])

    assert rows(table, 80) == [
             " n │ mid │ name",
             "───┼─────┼─────",
             " 1 │  a  │ x",
             "10 │ bbb │ y"
           ]
  end

  test "ragged rows are squared up with empty cells" do
    table = table(["a", "b", "c"], [["1"], ["2", "3", "4"]])

    assert rows(table, 80) == ["a │ b │ c", "──┼───┼──", "1 │   │", "2 │ 3 │ 4"]
  end

  test "an indent sits in front of every row and comes out of the width" do
    table = %{table(["a"], [["one two three"]]) | indent: 2}

    assert rows(table, 10) == ["  a", "  ────────", "  one two", "  three"]
  end

  test "the header is bright and the rule and separators are faint" do
    [header, rule | _body] = Table.rows(table(["Name"], [["x"]]), 80)

    assert [{"Name", %{bold: true}}] = header
    assert [{_dashes, %{foreground_color: 8}}] = rule
  end

  test "styled cells keep their styles" do
    [_header, _rule, row] = Table.rows(table(["a"], [[Text.tag("bold", :bright)]]), 80)

    assert [{"bold", %{bold: true}}] = row
  end
end
