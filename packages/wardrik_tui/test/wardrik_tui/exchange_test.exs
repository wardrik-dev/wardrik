defmodule WardrikTUI.ExchangeTest do
  use ExUnit.Case, async: true

  alias WardrikTUI.Exchange

  test "a call is recorded waiting, and its result completes it by id" do
    exchanges = Exchange.call(Exchange.new(), "call_1", "web_search", %{"query" => "lemonade"})

    assert [%Exchange{name: "web_search", output: nil, ok?: nil} = waiting] =
             Exchange.list(exchanges)

    refute Exchange.settled?(waiting)

    assert [%Exchange{output: "3 hits", ok?: true} = done] =
             exchanges
             |> Exchange.finish("call_1", "web_search", "3 hits", true)
             |> Exchange.list()

    assert Exchange.settled?(done)
  end

  test "without an id, a result completes the oldest call of its name still waiting" do
    exchanges =
      Exchange.new()
      |> Exchange.call(nil, "web_search", %{"query" => "a"})
      |> Exchange.call(nil, "web_search", %{"query" => "b"})
      |> Exchange.finish(nil, "web_search", "first", true)
      |> Exchange.finish(nil, "web_search", "second", false)

    assert [
             %{arguments: %{"query" => "a"}, output: "first", ok?: true},
             %{arguments: %{"query" => "b"}, output: "second", ok?: false}
           ] = Exchange.list(exchanges)
  end

  test "a call completed by id is not completed again by name" do
    exchanges =
      Exchange.new()
      |> Exchange.call("c1", "fetch", %{"n" => 1})
      |> Exchange.call("c2", "fetch", %{"n" => 2})
      |> Exchange.call("c3", "other", %{})
      |> Exchange.finish("c2", "fetch", "two", true)
      |> Exchange.finish(nil, "fetch", "one", true)
      |> Exchange.finish("c9", "other", "three", true)
      |> Exchange.finish(nil, "fetch", "stray", false)

    assert [
             %{id: "c1", output: "one"},
             %{id: "c2", output: "two"},
             %{id: "c3", output: "three"},
             %{id: nil, name: "fetch", arguments: %{}, output: "stray", ok?: false}
           ] = Exchange.list(exchanges)
  end

  test "a result by id completes that call again, even once it has one" do
    exchanges =
      Exchange.new()
      |> Exchange.call("c1", "fetch", %{})
      |> Exchange.finish(nil, "fetch", "first", true)
      |> Exchange.finish("c1", "fetch", "again", false)

    assert [%{id: "c1", output: "again", ok?: false}] = Exchange.list(exchanges)
  end

  test "a result nothing waits for is recorded on its own" do
    assert [%Exchange{name: "orphan", arguments: %{}, output: "x", ok?: true}] =
             Exchange.new() |> Exchange.finish("call_9", "orphan", "x", true) |> Exchange.list()
  end

  test "calls are found by their place, counting from 1" do
    exchanges = Exchange.new()
    assert Exchange.empty?(exchanges)
    assert Exchange.list(exchanges) == []

    exchanges = exchanges |> Exchange.call(nil, "a", %{}) |> Exchange.call(nil, "b", nil)

    refute Exchange.empty?(exchanges)
    assert %{name: "b", arguments: %{}} = Exchange.at(exchanges, 2)
    assert Exchange.at(exchanges, 3) == nil
    assert Exchange.at(exchanges, 0) == nil
  end
end
