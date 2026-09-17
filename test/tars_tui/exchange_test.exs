defmodule TarsTUI.ExchangeTest do
  use ExUnit.Case, async: true

  alias TarsTUI.Exchange

  test "a call is recorded waiting, and its result completes it by id" do
    exchanges = Exchange.call([], "call_1", "web_search", %{"query" => "lemonade"})

    assert [%Exchange{name: "web_search", output: nil, ok?: nil} = waiting] = exchanges
    refute Exchange.settled?(waiting)

    assert [%Exchange{output: "3 hits", ok?: true} = done] =
             Exchange.finish(exchanges, "call_1", "web_search", "3 hits", true)

    assert Exchange.settled?(done)
  end

  test "without an id, a result completes the oldest call of its name still waiting" do
    exchanges =
      []
      |> Exchange.call(nil, "web_search", %{"query" => "a"})
      |> Exchange.call(nil, "web_search", %{"query" => "b"})
      |> Exchange.finish(nil, "web_search", "first", true)
      |> Exchange.finish(nil, "web_search", "second", false)

    assert [
             %{arguments: %{"query" => "a"}, output: "first", ok?: true},
             %{arguments: %{"query" => "b"}, output: "second", ok?: false}
           ] = exchanges
  end

  test "a result nothing waits for is recorded on its own" do
    assert [%Exchange{name: "orphan", arguments: %{}, output: "x", ok?: true}] =
             Exchange.finish([], "call_9", "orphan", "x", true)
  end
end
