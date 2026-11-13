defmodule Wardrik.Workspace.SearchTest do
  use ExUnit.Case, async: true

  alias Wardrik.Workspace.File
  alias Wardrik.Workspace.Search
  alias Wardrik.Workspace.Search.BM25

  @now ~U[2026-11-12 12:00:00Z]

  defp file(content, days_ago \\ 0),
    do: %File{content: content, at: DateTime.add(@now, -days_ago, :day)}

  defp paths({:ok, hits}), do: Enum.map(hits, & &1.path)

  test "reads words, leaving out common ones and making plurals singular" do
    assert BM25.terms("The Pumpkin loaves are back, with 2 stories!") ==
             ["pumpkin", "loave", "back", "2", "story"]

    assert BM25.terms("posts glass bus") == ["post", "glass", "bus"]
  end

  test "ranks the files with more of the query's words, and rarer ones, first" do
    files = [
      {"digests/bread.md", file("Baked rye bread for the market.")},
      {"digests/launch.md", file("Posted the pumpkin loaf launch to X.")},
      {"notes/pumpkin.md", file("Pumpkin prices went up.")}
    ]

    assert paths(Search.search(files, "pumpkin loaf launch", now: @now)) ==
             ["digests/launch.md", "notes/pumpkin.md"]

    assert paths(Search.search(files, "rye", now: @now)) == ["digests/bread.md"]
    assert paths(Search.search(files, "sourdough", now: @now)) == []
  end

  test "quotes each file's best passage, from the line it starts on" do
    content = "# Week 45\n\nMonday: rye.\n\nTuesday: posted the pumpkin loaf.\nIt sold out.\n"

    assert {:ok, [%{line: 5, excerpt: "Tuesday: posted the pumpkin loaf.\nIt sold out."}]} =
             Search.search([{"digests/week.md", file(content)}], "pumpkin", now: @now)
  end

  test "ranks a newer file over an older one that matches as well, and keeps to the limit" do
    files = for days <- [90, 1, 30], do: {"day-#{days}.md", file("Pumpkin loaf.", days)}

    assert paths(Search.search(files, "pumpkin", now: @now)) == [
             "day-1.md",
             "day-30.md",
             "day-90.md"
           ]

    assert paths(Search.search(files, "pumpkin", now: @now, limit: 1)) == ["day-1.md"]
  end

  test "cuts a long passage to quote it" do
    long = String.duplicate("pumpkin ", 200)
    assert {:ok, [%{excerpt: excerpt}]} = Search.search([{"long.md", file(long)}], "pumpkin")
    assert byte_size(excerpt) <= 603
    assert String.ends_with?(excerpt, "…")
  end

  test "says when a query has no words to search for" do
    assert {:error, "\"the and\" has no words to search for"} =
             Search.search([{"a.md", file("x")}], "the and")
  end
end
