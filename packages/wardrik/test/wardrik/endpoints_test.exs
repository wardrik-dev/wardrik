defmodule Wardrik.EndpointsTest do
  use ExUnit.Case, async: false
  use Mimic

  import Wardrik.Test.LLM
  import Wardrik.Test.Wardrik

  @endpoint [model: "zai:glm-5.1", base_url: "http://localhost:9931/v1"]

  setup :set_mimic_global

  setup context do
    store_name = :"store #{context.test}"
    store = Wardrik.Test.Store.new(store_name)

    wardrik =
      Wardrik.new(
        authorizer: {Wardrik.Test.Allow, []},
        resolver: {Wardrik.Test.Owned, :"wardrik #{context.test}"},
        name: :"wardrik #{context.test}",
        store: store,
        endpoints: %{local: @endpoint},
        prices: %{"zai:glm-5.1" => [input: 2.0, output: 0.0]}
      )

    start_supervised!({Wardrik.Store, store})
    start_supervised!({Wardrik, wardrik})

    stub(ReqLLM.StreamResponse, :process_stream, fn response, _opts -> {:ok, response} end)
    event_log = Wardrik.events(wardrik)
    :ok = Wardrik.EventLog.subscribe(event_log, :all)
    %{scope: owner(wardrik)}
  end

  test "calls an agent's model at the endpoint it names, priced as its model", %{scope: scope} do
    test = self()

    stub(ReqLLM, :stream_text, fn model, _messages, opts ->
      send(test, {:called, model, opts[:base_url], opts[:api_key]})
      {:ok, %{answer("Done.") | usage: %{input_tokens: 1_000_000, output_tokens: 0}}}
    end)

    run!(scope, "agent.define", %{"agent" => "acme/scout", "model" => "local"})
    run!(scope, "agent.ask", %{"agent" => "acme/scout", "content" => "Look"})

    assert %{"data" => %{"cost" => %{"micro_usd" => 2_000_000}}} =
             until("wardrik.message.completed")

    assert_received {:called, "zai:glm-5.1", "http://localhost:9931/v1", "none"}
  end

  test "refuses a model that's neither a model nor an endpoint", %{scope: scope} do
    assert {:error, %Wardrik.Error{type: :invalid_request, message: message}} =
             Wardrik.run(scope, "agent.define", %{"agent" => "acme/scout", "model" => "remote"})

    assert message =~ "remote isn't a model or an endpoint."
  end
end
