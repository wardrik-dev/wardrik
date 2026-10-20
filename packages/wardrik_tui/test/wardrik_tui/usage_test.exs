defmodule WardrikTUI.UsageTest do
  use ExUnit.Case, async: true

  alias Wardrik.Bus
  alias Wardrik.Bus.ModelFinished
  alias Wardrik.LLM.Usage, as: Used
  alias WardrikTUI.Usage

  # A model call that ended, answered with `usage` where it is given, at
  # `micro_usd` where someone priced it.
  defp finished(usage, micro_usd \\ nil) do
    answer = usage && %{Wardrik.Test.LLM.final_answer("done") | usage: struct!(Used, usage)}
    cost = micro_usd && %{micro_usd: micro_usd, source: :provider}

    payload = %ModelFinished{
      message_id: "m0",
      outcome: :ok,
      duration_ms: 5,
      answer: answer,
      cost: cost
    }

    %Bus.Event{source: nil, payload: payload, at: 0}
  end

  test "starts at zero and says so" do
    assert Usage.empty?(Usage.new())
  end

  test "a call counts once it finishes with what its answer used" do
    usage = Usage.settle(Usage.new(), finished(%{input_tokens: 100, output_tokens: 40}))

    assert %{input: 100, output: 40, requests: 1} = usage
    refute Usage.empty?(usage)
  end

  test "calls add up, reasoning and cached tokens with them" do
    usage =
      Usage.new()
      |> Usage.settle(finished(%{input_tokens: 10, output_tokens: 1, reasoning_tokens: 5}))
      |> Usage.settle(finished(%{input_tokens: 20, output_tokens: 2, cached_tokens: 7}))

    assert %{input: 30, output: 3, reasoning: 5, cached: 7, requests: 2} = usage
  end

  test "a call costs what its event says, and nothing where nobody priced it" do
    usage =
      Usage.new()
      |> Usage.settle(finished(%{input_tokens: 1, output_tokens: 1}, 250_000))
      |> Usage.settle(finished(%{input_tokens: 1_000, output_tokens: 10}))

    assert usage.cost == 0.25
    assert usage.requests == 2
  end

  test "a call that never answered, or answered with no usage, adds no tokens" do
    usage =
      Usage.new()
      |> Usage.settle(finished(nil))
      |> Usage.settle(put_in(finished(%{}).payload.answer.usage, nil))

    assert %{input: 0, output: 0, requests: 1} = usage
  end

  test "the summary abbreviates and leaves out what is zero" do
    usage =
      Usage.settle(Usage.new(), finished(%{input_tokens: 12_345, output_tokens: 678}, 12_300))

    summary = Usage.summary(usage)

    assert summary =~ "↑ 12.3k in"
    assert summary =~ "↓ 678 out"
    assert summary =~ "$0.01"
    assert summary =~ "1 req"
    refute summary =~ "reasoning"
    refute summary =~ "cached"
  end
end
