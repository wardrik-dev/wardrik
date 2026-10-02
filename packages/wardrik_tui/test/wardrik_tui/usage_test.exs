defmodule WardrikTUI.UsageTest do
  use ExUnit.Case, async: true

  alias WardrikTUI.Usage

  defp meta(usage), do: %ReqLLM.StreamChunk{type: :meta, metadata: %{usage: usage}}

  test "starts at zero and says so" do
    assert Usage.empty?(Usage.new())
  end

  test "a request counts once it finishes, however many usage records it streamed" do
    usage =
      Usage.new()
      |> Usage.observe("s1", meta(%{input_tokens: 100}))
      |> Usage.observe("s1", meta(%{input_tokens: 100, output_tokens: 40}))

    assert Usage.empty?(usage)

    usage = Usage.settle(usage, "s1")

    assert %{input: 100, output: 40, requests: 1} = usage
    refute Usage.empty?(usage)
  end

  test "concurrent requests on different spans add up" do
    usage =
      Usage.new()
      |> Usage.observe("a", meta(%{input_tokens: 10, output_tokens: 1, reasoning_tokens: 5}))
      |> Usage.observe("b", meta(%{input_tokens: 20, output_tokens: 2, cached_tokens: 7}))
      |> Usage.settle("a")
      |> Usage.settle("b")

    assert %{input: 30, output: 3, reasoning: 5, cached: 7, requests: 2} = usage
  end

  test "the provider's cost is taken when it gives one" do
    usage =
      Usage.new()
      |> Usage.observe("a", meta(%{input_tokens: 1, output_tokens: 1, total_cost: 0.25}))
      |> Usage.settle("a")

    assert usage.cost == 0.25
  end

  test "the model is priced from the catalog when the first request settles" do
    usage = Usage.new({:anthropic, model: "claude-sonnet-5"})
    assert usage.model == nil

    usage =
      usage
      |> Usage.observe("a", meta(%{input_tokens: 1_000_000, output_tokens: 0}))
      |> Usage.settle("a")

    assert %{model: "claude-sonnet-5"} = usage.model
    assert usage.cost == 2.0
  end

  test "a model the catalog does not know costs nothing" do
    usage =
      Usage.new("test:model")
      |> Usage.observe("a", meta(%{input_tokens: 1_000, output_tokens: 10}))
      |> Usage.settle("a")

    assert usage.model == nil
    assert usage.cost == 0.0
    assert usage.requests == 1
  end

  test "metadata without usage, and a span that never reported, are ignored" do
    usage =
      Usage.new()
      |> Usage.observe("a", %ReqLLM.StreamChunk{type: :meta, metadata: %{finish_reason: :stop}})
      |> Usage.observe("a", %{tokens: 1})
      |> Usage.settle("a")
      |> Usage.settle("never")

    assert Usage.empty?(usage)
  end

  test "the summary abbreviates and leaves out what is zero" do
    usage =
      Usage.new()
      |> Usage.observe("a", meta(%{input_tokens: 12_345, output_tokens: 678, total_cost: 0.0123}))
      |> Usage.settle("a")

    summary = Usage.summary(usage)

    assert summary =~ "↑ 12.3k in"
    assert summary =~ "↓ 678 out"
    assert summary =~ "$0.01"
    assert summary =~ "1 req"
    refute summary =~ "reasoning"
    refute summary =~ "cached"
  end
end
