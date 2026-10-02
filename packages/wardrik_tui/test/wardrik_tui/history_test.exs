defmodule WardrikTUI.HistoryTest do
  use ExUnit.Case, async: true

  alias WardrikTUI.History

  defp with_lines(lines), do: Enum.reduce(lines, History.new(), &History.push(&2, &1))

  test "records lines newest first, once each in a row, and never a blank one" do
    history = with_lines(["first", "second", "second", "  ", "third"])

    assert History.entries(history) == ["third", "second", "first"]
  end

  test "keeps the newest lines up to its limit" do
    history = Enum.reduce(1..5, History.new(3), &History.push(&2, "line #{&1}"))

    assert History.entries(history) == ["line 5", "line 4", "line 3"]
  end

  test "walks back from the draft to the oldest, and forward to the draft again" do
    history = with_lines(["first", "second"])

    assert {"second", history} = History.back(history, "unfinished")
    assert History.browsing?(history)
    assert {"first", history} = History.back(history, "ignored")
    assert History.back(history, "ignored") == :none

    assert {"second", history} = History.forward(history)
    assert {"unfinished", history} = History.forward(history)
    refute History.browsing?(history)
    assert History.forward(history) == :none
  end

  test "an empty history has nothing to walk" do
    assert History.back(History.new(), "draft") == :none
    assert History.forward(History.new()) == :none
  end

  test "pushing or leaving drops the place held" do
    {_line, history} = History.back(with_lines(["first"]), "draft")

    refute History.browsing?(History.leave(history))
    refute History.browsing?(History.push(history, "second"))
  end
end
