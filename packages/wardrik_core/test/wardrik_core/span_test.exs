defmodule WardrikCore.SpanTest do
  use ExUnit.Case, async: true
  use Mimic

  import WardrikCore.Test.LLM

  alias WardrikCore.Context
  alias WardrikCore.Span
  alias WardrikCore.Test.Echo
  alias WardrikCore.Turn

  defmodule Charge do
    @behaviour WardrikCore.Middleware

    @impl true
    def call(%Context{step: {:tool_call, call}} = context, next, _opts) do
      context
      |> Context.attribute("gen_ai.tool.name", call.name)
      |> Context.measure(:usd, 0.25)
      |> next.()
    end

    def call(context, next, _opts), do: next.(context)
  end

  setup do
    stub(ReqLLM.StreamResponse, :process_stream, fn response, _opts -> {:ok, response} end)
    agent_id = "span-#{System.unique_integer([:positive])}"
    test = self()

    :telemetry.attach_many(
      agent_id,
      [[:wardrik_core, :step, :start], [:wardrik_core, :step, :stop]],
      fn [:wardrik_core, :step, event], measurements, metadata, _config ->
        if metadata.agent_id == agent_id, do: send(test, {event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(agent_id) end)

    context =
      Context.new(
        agent_id: agent_id,
        model: "anthropic:claude-haiku-4-5",
        capabilities: [Echo],
        middleware: [Charge],
        messages: [ReqLLM.Context.user("hi")],
        span: Span.root()
      )

    %{context: context}
  end

  test "each step is a span beneath the turn's", %{context: context} do
    ReqLLM
    |> expect(:stream_text, fn _, _, _ -> {:ok, calling([call("1", "echo", %{text: "a"})])} end)
    |> expect(:stream_text, fn _, _, _ -> {:ok, answer("done")} end)

    assert {:ok, _context} = Turn.run(context)

    assert_receive {:start, _, %{step: :turn, span: %Span{} = turn}}

    assert_receive {:start, _,
                    %{step: :generate, span: generate, model: "anthropic:claude-haiku-4-5"}}

    assert_receive {:start, _, %{step: {:tool_call, %{id: "1"}}, span: tool_call} = started}
    refute Map.has_key?(started, :model)

    assert turn.parent == context.span.id
    assert generate.parent == turn.id
    assert tool_call.parent == turn.id
    assert [context.span.trace] == Enum.uniq([turn.trace, generate.trace, tool_call.trace])
  end

  test "a step reports its attributes and what it measured", %{context: context} do
    used = %{input_tokens: 10, output_tokens: 2, total_cost: 0.01}

    ReqLLM
    |> expect(:stream_text, fn _, _, _ ->
      {:ok, %{calling([call("1", "echo", %{text: "a"})]) | usage: used}}
    end)
    |> expect(:stream_text, fn _, _, _ -> {:ok, %{answer("done") | usage: used}} end)

    assert {:ok, %Context{measurements: %{usd: 0.27, input_tokens: 20}}} = Turn.run(context)

    assert_receive {:stop, %{usd: 0.25},
                    %{
                      step: {:tool_call, _call},
                      status: :ok,
                      attributes: %{"gen_ai.tool.name" => "echo"},
                      response: {:ok, "a"}
                    }}

    assert_receive {:stop, %{input_tokens: 10, usd: 0.01, duration: _},
                    %{step: :generate, response: %ReqLLM.Response{}}}

    assert_receive {:stop, %{usd: 0.27, input_tokens: 20}, %{step: :turn}}
  end

  test "a step that fails reports why", %{context: context} do
    assert {:error, :nope} = Context.run(context, :generate, fn _context -> {:error, :nope} end)
    assert_receive {:stop, _measurements, %{step: :generate, status: :error, reason: :nope}}
  end

  test "a step can be named", %{context: context} do
    assert {:ok, %Context{step: nil}} =
             Context.run(context, {:step, "summarize"}, fn context -> {:ok, context} end)

    assert_receive {:start, _measurements, %{step: {:step, "summarize"}}}
  end

  test "a tool call runs under the same span after a restart", %{context: context} do
    assistant = calling([call("1", "echo", %{text: "a"})]).message

    checkpoint = %{
      messages: context.messages ++ [assistant],
      calls: Enum.map(assistant.tool_calls, &WardrikCore.ToolCall.from_req_llm/1),
      rounds: 3,
      metadata: %{},
      private: %{},
      span: context.span,
      measurements: %{}
    }

    stub(ReqLLM, :stream_text, fn _, _, _ -> {:ok, answer("done")} end)

    Turn.recover(context, checkpoint)
    assert_receive {:start, _, %{step: {:tool_call, _}, span: first}}

    Turn.recover(context, checkpoint)
    assert_receive {:start, _, %{step: {:tool_call, _}, span: second}}

    assert first.id == second.id
  end
end
