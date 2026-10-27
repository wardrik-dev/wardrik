defmodule Wardrik.PricesTest do
  use ExUnit.Case, async: false
  use Mimic

  import Wardrik.Test.LLM
  import Wardrik.Test.Wardrik

  @model "zai_coding_plan:glm-5.1"

  setup :set_mimic_global

  setup context do
    store = Wardrik.Test.Store.new(:"store #{context.test}")

    wardrik =
      Wardrik.new(
        name: :"wardrik #{context.test}",
        store: store,
        prices: %{@model => [priced_as: "zai:glm-5.1", markup: 0.5]}
      )

    start_supervised!({WardrikStore, store})
    start_supervised!({Wardrik, wardrik})

    stub(ReqLLM.StreamResponse, :process_stream, fn response, _opts -> {:ok, response} end)
    :ok = WardrikEvents.subscribe(Wardrik.events(wardrik), ["*"])
    %{wardrik: wardrik, scope: owner(wardrik)}
  end

  test "counts a model call at the price it's given", %{wardrik: wardrik, scope: scope} do
    stub(ReqLLM, :stream_text, fn _model, _messages, _opts ->
      {:ok, %{answer("Done.") | usage: %{input_tokens: 1_000_000, output_tokens: 0}}}
    end)

    run!(scope, "agent.define", %{"agent" => "acme/scout", "model" => @model})
    run!(scope, "agent.ask", %{"agent" => "acme/scout", "content" => "Look"})

    assert %{"data" => %{"cost" => %{"micro_usd" => 2_100_000}}} =
             until("wardrik.message.completed")

    assert %{"usd" => usd} = Wardrik.Spending.today(wardrik, "acme/scout")
    assert_in_delta usd, 2.1, 1.0e-9
  end

  test "reads a price from its rates, or another model's" do
    assert Wardrik.Setup.price("x:y", input: 1.0, output: 2.0, markup: 1.0) == [
             input: 2.0,
             output: 4.0
           ]

    assert_raise ArgumentError, "x:y's price gives its input and output.", fn ->
      Wardrik.Setup.price("x:y", input: 1.0)
    end

    assert_raise ArgumentError, "x:y's price has no per.", fn ->
      Wardrik.Setup.price("x:y", input: 1.0, output: 1.0, per: :day)
    end

    assert_raise ArgumentError, "x:y's price is another model's or its own.", fn ->
      Wardrik.Setup.price("x:y", priced_as: "zai:glm-5.1", input: 1.0)
    end

    assert_raise ArgumentError, "nope:nope has no price in dollars to price x:y as.", fn ->
      Wardrik.Setup.price("x:y", priced_as: "nope:nope")
    end
  end
end
