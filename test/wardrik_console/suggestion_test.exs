defmodule WardrikConsole.SuggestionTest do
  use ExUnit.Case, async: true

  alias WardrikConsole.Suggestion

  test "the names near a word, nearest first, and none where nothing is near" do
    assert Suggestion.closest("stauts", ["status", "stop", "start"]) == ["status", "start"]
    assert Suggestion.closest("frobnicate", ["status", "stop"]) == []
  end

  test "at most three" do
    assert [_first, _second, _third] =
             Suggestion.closest("tokn", ["token", "tokens", "tokenise", "tokened"])
  end
end
