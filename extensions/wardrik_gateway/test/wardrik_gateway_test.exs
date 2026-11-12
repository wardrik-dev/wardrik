defmodule WardrikGatewayTest do
  use ExUnit.Case, async: true

  alias WardrikCore.Context

  @haiku "anthropic:claude-haiku-4-5-20251001"
  @mini "openai:gpt-4o-mini"
  @glm "zai:glm-5.1"

  setup context do
    name = :"gateway #{context.test}"
    opts = Map.get(context, :gateway, fallbacks: %{@haiku => [@mini, @glm]})
    start_supervised!({WardrikGateway, [name: name] ++ opts})

    test = self()
    events = [:failover, :limited, :breaker_opened, :breaker_closed]

    :telemetry.attach_many(
      name,
      Enum.map(events, &[:wardrik_gateway, &1]),
      fn event, measurements, metadata, _config ->
        send(test, {event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(name) end)
    %{gateway: name}
  end

  defp generate(gateway, answers) do
    {:ok, queue} = Agent.start_link(fn -> answers end)
    context = %{Context.new(agent_id: "acme/triage", model: @haiku) | step: :generate}

    WardrikGateway.call(context, fn context -> answered(queue, context) end, gateway)
  end

  defp answered(queue, context) do
    send(self(), {:called, context.model})

    case Agent.get_and_update(queue, fn [next | rest] -> {next, rest} end) do
      :ok -> {:ok, %{context | response: response()}}
      :bare -> {:ok, context}
      {status, headers} -> {:error, %ReqLLM.Error.API.Request{status: status, headers: headers}}
      status -> {:error, %ReqLLM.Error.API.Request{status: status, reason: "down"}}
    end
  end

  defp response do
    %ReqLLM.Response{
      id: "r",
      model: "m",
      context: nil,
      message: ReqLLM.Context.assistant("Hi."),
      usage: %{input_tokens: 10, output_tokens: 5}
    }
  end

  test "passes a step other than a model call straight through", %{gateway: gateway} do
    context = %{Context.new(agent_id: "acme/triage", model: @haiku) | step: :turn}
    assert {:ok, ^context} = WardrikGateway.call(context, &{:ok, &1}, gateway)
  end

  test "moves a failed call to the next model, and stays on it", %{gateway: gateway} do
    assert {:ok, %Context{model: @mini}} = generate(gateway, [503, :ok])
    assert_received {:called, @haiku}
    assert_received {:called, @mini}

    assert_received {[:wardrik_gateway, :failover], %{},
                     %{from: @haiku, to: @mini, agent_id: "acme/triage"}}
  end

  test "answers a failure a retry won't fix at once", %{gateway: gateway} do
    assert {:error, %ReqLLM.Error.API.Request{status: 400}} = generate(gateway, [400])
    refute_received {:called, @mini}
  end

  test "answers the last failure once every model failed", %{gateway: gateway} do
    assert {:error, %ReqLLM.Error.API.Request{status: 529}} = generate(gateway, [503, 429, 529])
  end

  @tag gateway: [breaker: [failures: 1, open_for: 60_000], wait: 0]
  test "skips an open model, and answers Unavailable when none can take the call in time", %{
    gateway: gateway
  } do
    assert {:error, %ReqLLM.Error.API.Request{status: 503}} = generate(gateway, [503])
    assert_received {:called, @haiku}
    assert_receive {[:wardrik_gateway, :breaker_opened], %{}, %{model: @haiku}}

    assert {:error, %WardrikGateway.Unavailable{models: [@haiku]} = unavailable} =
             generate(gateway, [:ok])

    assert Exception.message(unavailable) =~ @haiku
    refute_received {:called, _model}
  end

  test "holds a call until its provider has room", %{gateway: gateway} do
    GenServer.cast(gateway, {:report, @haiku, {:limited, 50}})
    assert {:ok, _context} = generate(gateway, [:ok])
    assert_received {[:wardrik_gateway, :limited], %{wait: wait}, %{model: @haiku}}
    assert wait in 1..50
  end

  test "holds a provider as long as its 429 says, from either header shape", %{gateway: gateway} do
    for {headers, held} <- [
          {[{"retry-after", "7"}], 7_000},
          {%{"retry-after" => ["9"]}, 9_000},
          {[{"retry-after", "Wed, 21 Oct 2026 07:28:00 GMT"}], 1_000},
          {nil, 1_000}
        ] do
      fresh = :"#{gateway} #{held} #{inspect(headers)}"
      start_supervised!({WardrikGateway, name: fresh}, id: fresh)
      assert {:error, %{status: 429}} = generate(fresh, [{429, headers}])
      assert {:wait, wait} = GenServer.call(fresh, {:admit, [@haiku], 0})
      assert wait in (held - 100)..held
    end
  end

  test "counts no tokens for a call that answered none", %{gateway: gateway} do
    assert {:ok, %Context{model: @haiku}} = generate(gateway, [:bare])
  end

  test "takes new settings while it runs, as its schema says", %{gateway: gateway} do
    assert Keyword.has_key?(WardrikGateway.schema().schema, :fallbacks)
    :ok = WardrikGateway.configure(gateway, fallbacks: %{@haiku => [@glm]})
    assert {:ok, %Context{model: @glm}} = generate(gateway, [503, :ok])
  end
end
