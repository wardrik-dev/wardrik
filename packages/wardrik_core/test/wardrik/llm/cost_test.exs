defmodule Wardrik.LLM.CostTest do
  use ExUnit.Case, async: true

  alias Wardrik.LLM.Cost
  alias Wardrik.LLM.Usage

  # A client that prices a token at a millionth of a dollar, and one that
  # prices nothing.
  @priced %Wardrik.Test.LLM{script: nil, price: 0.000_001}
  @unpriced %Wardrik.Test.LLM{script: nil}

  test "the provider's own total wins" do
    usage = %Usage{input_tokens: 1, total_cost: 0.25}

    assert Cost.of(@unpriced, "test:model", usage) == 0.25
    assert Cost.price(@unpriced, "test:model", usage) == %{micro_usd: 250_000, source: :provider}
  end

  test "tokens are priced by the client" do
    usage = %Usage{input_tokens: 10_000, output_tokens: 2_000}

    assert_in_delta Cost.of(@priced, "test:model", usage), 0.012, 1.0e-12
    assert Cost.price(@priced, "test:model", usage) == %{micro_usd: 12_000, source: :catalog}
  end

  test "a model the client does not price costs nil, and so does a call that used nothing" do
    assert Cost.of(@unpriced, "test:model", %Usage{input_tokens: 10, output_tokens: 10}) == nil
    assert Cost.price(@unpriced, "test:model", %Usage{input_tokens: 10}) == nil
    assert Cost.of(@priced, "test:model", nil) == nil
    assert Cost.price(@priced, "test:model", nil) == nil
  end

  test "priced?/2 says whether the client prices a model" do
    assert Cost.priced?(@priced, "test:model")
    refute Cost.priced?(@unpriced, "test:model")
  end
end
