defmodule Tars.LLM.TurnTest do
  use ExUnit.Case, async: true

  use Mimic

  alias ReqLLM.Context
  alias Tars.Event
  alias Tars.LLM
  alias Tars.Scope
  alias Tars.Test.LLMStub

  setup :verify_on_exit!

  setup do
    agent_id = make_ref()
    :ok = Event.Bus.subscribe(agent_id)
    {:ok, agent_id: agent_id}
  end

  defp scope(agent_id, tools \\ []) do
    LLM.Config.new(tools: tools) |> Scope.root(agent_id, name: "turn")
  end

  describe "the persona" do
    test "is prepended per call rather than stored in the conversation", %{agent_id: agent_id} do
      test_pid = self()

      LLMStub.answering(fn asked ->
        send(test_pid, {:asked, asked})
        {:ok, LLMStub.final_answer("done")}
      end)

      scope =
        [system: "You answer briefly."]
        |> LLM.Config.new()
        |> Scope.root(agent_id, name: "turn")

      assert {:ok, messages} = LLM.Turn.run(scope, Context.new([Context.user("hi")]))

      assert_receive {:asked, %{system: "You answer briefly."}}
      refute Enum.any?(messages, &(&1.role == :system))
    end

    test "is left out entirely when a config has none", %{agent_id: agent_id} do
      test_pid = self()

      LLMStub.answering(fn asked ->
        send(test_pid, {:asked, asked})
        {:ok, LLMStub.final_answer("done")}
      end)

      assert {:ok, _messages} = LLM.Turn.run(scope(agent_id), Context.new())

      assert_receive {:asked, %{system: nil}}
    end
  end

  test "a final answer terminates the loop and returns the assistant message", %{
    agent_id: agent_id
  } do
    LLMStub.stream([LLMStub.final_answer("hello")])

    assert {:ok, [message]} = LLM.Turn.run(scope(agent_id), Context.new())
    assert message.role == :assistant
  end

  test "tool calls loop once, then terminate on the final answer", %{agent_id: agent_id} do
    tool = ReqLLM.Tool.new!(name: "echo", description: "echo", callback: fn i -> {:ok, i} end)

    LLMStub.stream([
      LLMStub.tool_call("call_1", "echo", %{"input" => "hi"}),
      LLMStub.final_answer("done")
    ])

    context = Context.new([Context.user("hi")])

    assert {:ok, messages} = LLM.Turn.run(scope(agent_id, [tool]), context)

    # assistant(tool_use) -> tool(result) -> assistant(final), in order, and the
    # pre-existing user message is NOT re-reported: this is a delta.
    assert Enum.map(messages, & &1.role) == [:assistant, :tool, :assistant]
    assert_receive %Event{payload: {:tool_started, "call_1", "echo"}}
    assert_receive %Event{payload: {:tool_finished, "call_1", "echo", {:ok, %{"input" => "hi"}}}}
  end

  test "stream callbacks are published as events for the agent", %{agent_id: agent_id} do
    :ok = Event.Bus.unsubscribe(agent_id)
    :ok = Event.Bus.subscribe(agent_id, level: :raw)
    LLMStub.stream([LLMStub.final_answer("hello")])

    assert {:ok, _messages} = LLM.Turn.run(scope(agent_id), Context.new())

    assert_receive %Event{payload: {:chunk, "chunk"}}
    assert_receive %Event{payload: {:meta, %{tokens: 1}}}
    assert_receive %Event{payload: {:thinking, "thinking"}}
    assert_receive %Event{payload: {:result, "result"}}
    assert_receive %Event{payload: {:tool_call, %{name: "echo"}}}
  end

  test "the model request announces both ends", %{agent_id: agent_id} do
    LLMStub.stream([LLMStub.final_answer("hello")])

    assert {:ok, _messages} = LLM.Turn.run(scope(agent_id), Context.new())

    assert_receive %Event{payload: {:model_started, _model_spec}}
    assert_receive %Event{payload: {:model_finished, :ok, _ms}}
  end

  test "a failed request is announced before the turn gives up", %{agent_id: agent_id} do
    Mimic.stub(ReqLLM, :stream_text, fn _model, _context, _opts -> {:error, :rate_limited} end)

    {_result, _log} =
      ExUnit.CaptureLog.with_log(fn -> LLM.Turn.run(scope(agent_id), Context.new()) end)

    assert_receive %Event{payload: {:model_started, _model_spec}}
    assert_receive %Event{payload: {:model_finished, {:error, :rate_limited}, _ms}}
  end

  test "stream events are not published to other agents", %{agent_id: agent_id} do
    LLMStub.stream([LLMStub.final_answer("hello")])

    assert {:ok, _messages} = LLM.Turn.run(scope(make_ref()), Context.new())

    refute_receive %Event{}
    assert Event.Bus.subscribers(agent_id) == [self()]
  end

  test "a stream error aborts the turn", %{agent_id: agent_id} do
    stub(ReqLLM, :stream_text, fn _model, _context, _opts -> {:error, :rate_limited} end)

    assert capture(fn -> LLM.Turn.run(scope(agent_id), Context.new()) end) ==
             {:error, :rate_limited}
  end

  test "a response with no assistant message falls back to the classified text", %{
    agent_id: agent_id
  } do
    LLMStub.stream([LLMStub.response(nil, :stop)])

    assert {:ok, [message]} = LLM.Turn.run(scope(agent_id), Context.new())
    assert message.role == :assistant
  end

  test "provider-executed calls are not run as tools and end the turn", %{agent_id: agent_id} do
    call = ReqLLM.ToolCall.new("call_1", "web_search", "{}")
    builtin = %{call | function: Map.put(call.function, :builtin?, true)}

    LLMStub.stream([LLMStub.response(Context.assistant("", tool_calls: [builtin]), :tool_calls)])

    assert {:ok, [message]} = LLM.Turn.run(scope(agent_id), Context.new())
    assert message.role == :assistant
    refute_receive %Event{payload: {:tool_started, _, _}}
  end

  test "an unpairable tool exchange aborts rather than looping", %{agent_id: agent_id} do
    tool = ReqLLM.Tool.new!(name: "echo", description: "echo", callback: fn i -> {:ok, i} end)

    # An empty call id fails ToolExchange's `valid_call?/1`, so results can
    # never be matched back to the assistant message.
    LLMStub.stream([LLMStub.tool_call("", "echo", %{})])

    assert {:error, _reason} =
             capture(fn -> LLM.Turn.run(scope(agent_id, [tool]), Context.new()) end)
  end

  test "the iteration cap stops a model that never stops calling tools", %{agent_id: agent_id} do
    tool = ReqLLM.Tool.new!(name: "echo", description: "echo", callback: fn i -> {:ok, i} end)

    LLMStub.stream(List.duplicate(LLMStub.tool_call("call_1", "echo", %{}), 30))

    assert {:ok, messages} =
             capture(fn -> LLM.Turn.run(scope(agent_id, [tool]), Context.new()) end)

    # 25 iterations, each appending an assistant message and its tool result.
    assert Enum.count_until(messages, 51) == 50
  end

  defp capture(fun) do
    {result, _log} = ExUnit.CaptureLog.with_log(fun)
    result
  end
end
