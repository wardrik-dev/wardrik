defmodule Tars.LLM.CostTest do
  use ExUnit.Case, async: true

  alias Tars.LLM.Cost
  alias Tars.Test.LLMStub

  test "the provider's own total wins" do
    assert Cost.of("anthropic:claude-sonnet-5", %{input_tokens: 1, total_cost: 0.25}) == 0.25
  end

  test "tokens are priced by the catalog's entry for the model" do
    cost = Cost.of("anthropic:claude-sonnet-5", %{input_tokens: 10_000, output_tokens: 2_000})
    assert is_float(cost) and cost > 0
  end

  test "a model the catalog does not price costs nil" do
    assert Cost.of("nowhere:no-such-model", %{input_tokens: 10, output_tokens: 10}) == nil
    assert Cost.of("anthropic:claude-sonnet-5", nil) == nil
  end

  test "priced?/1 says whether the catalog prices a model" do
    assert Cost.priced?("anthropic:claude-sonnet-5")
    assert Cost.priced?({:zai_coding_plan, model: "glm-5.3-flash"})
    refute Cost.priced?("nowhere:no-such-model")
  end

  test "of_response/2 prices a response by its usage" do
    response = %{LLMStub.final_answer("done") | usage: %{total_cost: 0.5}}
    assert Cost.of_response("anthropic:claude-sonnet-5", response) == 0.5
  end
end
