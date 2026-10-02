defmodule WardrikTUI.SearchTest do
  use ExUnit.Case, async: true

  alias WardrikTUI.Search
  alias WardrikTUI.Transcript

  setup do
    transcript =
      Transcript.append_all(Transcript.new(40), ["alpha one", "beta", "alpha two", "gamma"])

    {:ok, transcript: transcript}
  end

  test "starts at the match holding the row given, or the first", %{transcript: transcript} do
    assert %Search{query: "alpha", at: 1} = Search.new("alpha", transcript, 2)
    assert %Search{at: 0} = Search.new("alpha", transcript)
    assert Search.rows(transcript, "ALPHA") == [0, 2]
  end

  test "steps round the matches both ways", %{transcript: transcript} do
    search = Search.new("alpha", transcript)

    assert {%Search{at: 1} = search, 2, 2} = Search.step(search, transcript, :next)
    assert {%Search{at: 0} = search, 0, 2} = Search.step(search, transcript, :next)
    assert {%Search{at: 1}, 2, 2} = Search.step(search, transcript, :previous)
  end

  test "says so when nothing matches any more", %{transcript: transcript} do
    assert Search.step(%Search{query: "delta"}, transcript, :next) == :none
  end
end
