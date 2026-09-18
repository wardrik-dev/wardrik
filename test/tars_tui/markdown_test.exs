defmodule TarsTUI.MarkdownTest do
  use ExUnit.Case, async: true

  alias TarsTUI.Markdown
  alias TarsTUI.Text

  defp plain(data), do: Text.plain(data)

  defp sequences(%Text{sequences: sequences, data: data}), do: sequences ++ sequences(data)
  defp sequences(list) when is_list(list), do: Enum.flat_map(list, &sequences/1)
  defp sequences(_other), do: []

  defp render(text), do: text |> Markdown.line() |> plain()

  defp push(text), do: Markdown.push(Markdown.new(), text)

  describe "code_blocks/1" do
    test "returns the body of each fenced block, in order, and nothing without one" do
      text = "Here:\n```elixir\nIO.puts(1)\n```\nand\n~~~\necho hi\necho there\n~~~\ndone"

      assert Markdown.code_blocks(text) == ["IO.puts(1)", "echo hi\necho there"]
      assert Markdown.code_blocks("no code here") == []
    end
  end

  describe "push/2" do
    test "returns nothing until a line is complete" do
      assert {[], buffer} = push("some pro")
      assert plain(Markdown.tail(buffer)) == "some pro"
    end

    test "returns each line as it completes" do
      assert {[one, two], buffer} = push("first\nsecond\nthi")

      assert plain(one) == "first"
      assert plain(two) == "second"
      assert plain(Markdown.tail(buffer)) == "thi"
    end

    test "picks up where it left off across calls" do
      {[], buffer} = push("some ")
      {lines, buffer} = Markdown.push(buffer, "prose\n")

      assert Enum.map(lines, &plain/1) == ["some prose"]
      assert Markdown.tail(buffer) == nil
    end

    test "a trailing newline leaves nothing pending" do
      assert {[_line], buffer} = push("done\n")
      assert Markdown.tail(buffer) == nil
    end

    test "blank lines survive as blank lines" do
      {lines, _buffer} = push("one\n\ntwo\n")

      assert Enum.map(lines, &plain/1) == ["one", "", "two"]
    end
  end

  describe "flush/1" do
    test "renders what never got its newline" do
      {[], buffer} = push("the last word")
      {lines, buffer} = Markdown.flush(buffer)

      assert Enum.map(lines, &plain/1) == ["the last word"]
      assert Markdown.tail(buffer) == nil
    end

    test "an empty buffer flushes nothing" do
      assert {[], _buffer} = Markdown.flush(Markdown.new())
    end
  end

  describe "block constructs" do
    test "headings lose their hashes and gain colour" do
      assert render("## The component model") == "The component model"
      assert Markdown.line("# Title") |> sequences() |> Enum.member?(:bright)
      refute Markdown.line("### Deep") |> sequences() |> Enum.member?(:bright)
    end

    test "bullets become bullets, keeping their indent" do
      assert render("- first") == "• first"
      assert render("* second") == "• second"
      assert render("  - nested") == "  • nested"
    end

    test "ordered items keep their number" do
      assert render("1. first") == "1. first"
      assert render("2) second") == "2. second"
    end

    test "block quotes are marked and dimmed" do
      assert render("> quoted") == "│ quoted"
      assert Markdown.line("> quoted") |> sequences() |> Enum.member?(:faint)
    end

    test "horizontal rules become a divider" do
      assert render("---") =~ "─"
      assert render("***") =~ "─"
    end

    test "ordinary prose passes through" do
      assert render("It defines a binary interface.") == "It defines a binary interface."
    end
  end

  describe "inline constructs" do
    test "bold, emphasis and code lose their markers" do
      assert render("a **bold** word") == "a bold word"
      assert render("an *emphatic* word") == "an emphatic word"
      assert render("an _emphatic_ word") == "an emphatic word"
      assert render("the `mix test` command") == "the mix test command"
    end

    test "each marker gets its own sequence" do
      assert Markdown.line("**bold**") |> sequences() |> Enum.member?(:bright)
      assert Markdown.line("*em*") |> sequences() |> Enum.member?(:italic)
      assert Markdown.line("`code`") |> sequences() |> Enum.member?(:cyan)
    end

    test "links render as their text, hyperlinked" do
      assert render("see [the docs](https://example.com)") == "see the docs"

      assert Markdown.line("[the docs](https://example.com)")
             |> sequences()
             |> Enum.member?({:hyperlink, "https://example.com"})
    end

    test "a bare link shows its url" do
      assert render("[](https://example.com)") == "https://example.com"
    end

    test "inline markers work inside bullets and headings" do
      assert render("- a **bold** point") == "• a bold point"
      assert render("## a `code` heading") == "a code heading"
    end

    test "an unmatched marker is left alone" do
      assert render("2 * 3 * 4 =") == "2 * 3 * 4 ="
      assert render("a lone ` backtick") == "a lone ` backtick"
    end
  end

  describe "fenced code" do
    test "code inside a fence is indented and not treated as markdown" do
      {lines, _buffer} = push("```\n# not a heading\n- not a bullet\n```\n")

      assert Enum.map(lines, &plain/1) == ["", "  # not a heading", "  - not a bullet", ""]
    end

    test "the language is kept as a label" do
      {[label | _rest], _buffer} = push("```elixir\ncode\n```\n")

      assert plain(label) == "elixir"
    end

    test "the fence survives across pushes" do
      {_lines, buffer} = push("```\ncode\n")
      assert buffer.fenced?

      {lines, buffer} = Markdown.push(buffer, "# still code\n```\n")

      assert Enum.map(lines, &plain/1) == ["  # still code", ""]
      refute buffer.fenced?
    end

    test "an unclosed fence still flushes its last line as code" do
      {_lines, buffer} = push("```\ncode")
      {lines, _buffer} = Markdown.flush(buffer)

      assert Enum.map(lines, &plain/1) == ["  code"]
    end
  end

  test "a whole streamed answer renders in order" do
    answer = """
    ## Findings

    The **component model** defines an ABI. See [the spec](https://example.com).

    - it is stable
    - it is `wasm`-native

    ```elixir
    def run, do: :ok
    ```
    """

    {lines, buffer} =
      answer
      |> String.graphemes()
      |> Enum.reduce({[], Markdown.new()}, fn char, {acc, buffer} ->
        {lines, buffer} = Markdown.push(buffer, char)
        {acc ++ lines, buffer}
      end)

    {last, _buffer} = Markdown.flush(buffer)

    assert Enum.map(lines ++ last, &plain/1) == [
             "Findings",
             "",
             "The component model defines an ABI. See the spec.",
             "",
             "• it is stable",
             "• it is wasm-native",
             "",
             "elixir",
             "  def run, do: :ok",
             ""
           ]
  end

  describe "tables" do
    alias TarsTUI.Table

    defp cells(row), do: Enum.map(row, &plain/1)

    test "rows are held back until the table ends, then returned as one table" do
      {lines, buffer} =
        Markdown.push(
          Markdown.new(),
          "| Name | Price |\n|---|--:|\n| **Breadtopia** | $18 |\n| King Arthur | $9.95 |\n"
        )

      assert lines == []

      {[%Table{} = table, after_it], _buffer} = Markdown.push(buffer, "after\n")

      assert cells(table.header) == ["Name", "Price"]
      assert Enum.map(table.rows, &cells/1) == [["Breadtopia", "$18"], ["King Arthur", "$9.95"]]
      assert table.alignments == [:left, :right]
      assert plain(after_it) == "after"
    end

    test "cells keep their inline styles" do
      {[%Table{rows: [[name, _price]]}], _buffer} =
        Markdown.new()
        |> Markdown.push("| a | b |\n|---|---|\n| **Bold** | 1 |\n")
        |> elem(1)
        |> Markdown.flush()

      assert sequences(name) |> Enum.member?(:bright)
    end

    test "a table still pending at the end of the stream is flushed" do
      {[], buffer} = Markdown.push(Markdown.new(), "| a | b |\n| c | dd |")
      {[%Table{} = table], _buffer} = Markdown.flush(buffer)

      assert cells(table.header) == ["a", "b"]
      assert Enum.map(table.rows, &cells/1) == [["c", "dd"]]
      assert table.alignments == [:left, :left]
    end

    test "a table inside a fence is code" do
      {lines, _buffer} = Markdown.push(Markdown.new(), "```\n| a | b |\n```\n")

      assert Enum.map(lines, &plain/1) == ["", "  | a | b |", ""]
    end
  end
end
