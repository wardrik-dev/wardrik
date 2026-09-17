defmodule TarsTUI.TranscriptTest do
  use ExUnit.Case, async: true

  alias TarsTUI.Text
  alias TarsTUI.Transcript

  test "starts empty" do
    transcript = Transcript.new(40)

    assert Transcript.rows(transcript) == 0
    assert Transcript.to_list(transcript) == []
  end

  test "keeps lines in order" do
    transcript = Transcript.new(40) |> Transcript.append("one") |> Transcript.append("two")

    assert Transcript.to_list(transcript) == ["one", "two"]
  end

  test "data with newlines becomes several rows, a trailing newline none" do
    transcript = Transcript.append(Transcript.new(40), ["a\nb\n", Text.tag("c\n\n", :red)])

    assert Transcript.to_list(transcript) == ["a", "b", "c", ""]
  end

  test "find/2 lists the rows holding the text, ignoring case, and nothing for no text" do
    transcript =
      Transcript.append_all(Transcript.new(40), ["Lemonade stand", "tea", "more LEMONADE"])

    assert Transcript.find(transcript, "lemon") == [{0, "Lemonade stand"}, {2, "more LEMONADE"}]
    assert Transcript.find(transcript, "coffee") == []
    assert Transcript.find(transcript, "") == []
  end

  test "an empty line is a row" do
    assert Transcript.to_list(Transcript.append(Transcript.new(40), "")) == [""]
  end

  test "wraps at the width, on word boundaries, dropping the space it broke on" do
    transcript = Transcript.append(Transcript.new(12), "aaaa bbbb cccc dddd")

    assert Transcript.to_list(transcript) == ["aaaa bbbb", "cccc dddd"]
  end

  test "a word wider than the width is broken mid-word" do
    transcript = Transcript.append(Transcript.new(4), "abcdefghij")

    assert Transcript.to_list(transcript) == ["abcd", "efgh", "ij"]
  end

  test "styles survive wrapping" do
    transcript =
      Transcript.append(Transcript.new(12), ["aaaa ", Text.tag("bbbb cccc", :cyan)])

    assert Transcript.to_list(transcript) == ["aaaa bbbb", "cccc"]

    source = Transcript.source(transcript)

    assert source.slice_fn.(0, 2, 12) == [
             [{"aaaa ", %{}}, {"bbbb", %{foreground_color: 6}}],
             [{"cccc", %{foreground_color: 6}}]
           ]
  end

  test "wrapped rows hang under a bullet or indentation" do
    transcript = Transcript.append(Transcript.new(14), "  • aaaa bbbb cccc dddd")

    assert Transcript.to_list(transcript) == ["  • aaaa bbbb", "    cccc dddd"]

    transcript = Transcript.append(Transcript.new(12), "1. aaaa bbbb cccc")
    assert Transcript.to_list(transcript) == ["1. aaaa bbbb", "   cccc"]

    transcript = Transcript.append(Transcript.new(14), "  • aaaa bbbb cccc dddd eeee ffff")
    assert Transcript.to_list(transcript) == ["  • aaaa bbbb", "    cccc dddd", "    eeee ffff"]
  end

  test "a line opening with a bar repeats the bar on every wrapped row" do
    transcript = Transcript.append(Transcript.new(12), [Text.tag("│ ", :cyan), "aaaa bbbb cccc"])

    assert Transcript.to_list(transcript) == ["│ aaaa bbbb", "│ cccc"]

    [_first, second] = Transcript.source(transcript).slice_fn.(0, 2, 12)
    assert [{"│ ", %{foreground_color: 6}}, {"cccc", %{}}] = second

    transcript = Transcript.append(Transcript.new(14), ["  ", "┊ aaaa bbbb cccc"])
    assert Transcript.to_list(transcript) == ["  ┊ aaaa bbbb", "  ┊ cccc"]
  end

  test "trailing spaces never make a row of their own" do
    transcript = Transcript.append(Transcript.new(8), "aaaa" <> String.duplicate(" ", 20))

    assert Transcript.to_list(transcript) == ["aaaa"]

    transcript = Transcript.append(Transcript.new(8), "aaaa bbbb   ")
    assert Transcript.to_list(transcript) == ["aaaa", "bbbb"]
  end

  test "a table is laid out to the width and again on rewrap" do
    table = TarsTUI.Table.new(["a", "b"], [["1", "one two three"]])
    transcript = Transcript.append(Transcript.new(40), table)

    assert Transcript.to_list(transcript) == ["a │ b", "──┼──────────────", "1 │ one two three"]

    assert Transcript.to_list(Transcript.rewrap(transcript, 12)) == [
             "a │ b",
             "──┼─────────",
             "1 │ one two",
             "  │ three"
           ]
  end

  test "rewrapping at a new width keeps every line" do
    transcript =
      Transcript.new(40)
      |> Transcript.append("aaaa bbbb cccc dddd")
      |> Transcript.append("")
      |> Transcript.rewrap(12)

    assert Transcript.to_list(transcript) == ["aaaa bbbb", "cccc dddd", ""]
    assert Transcript.rewrap(transcript, 12) == transcript
  end

  test "the source answers Breeze with exactly the rows it asks for" do
    transcript = Transcript.append_all(Transcript.new(40), ~w(a b c d e))
    source = Transcript.source(transcript)

    assert source.line_count_fn.(40) == 5
    assert source.slice_fn.(1, 2, 40) == [[{"b", %{}}], [{"c", %{}}]]
    assert source.slice_fn.(4, 10, 40) == [[{"e", %{}}]]
    assert source.slice_fn.(5, 1, 40) == []
  end
end
