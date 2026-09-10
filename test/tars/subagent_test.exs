defmodule Tars.SubagentTest do
  use ExUnit.Case, async: true

  use Mimic

  alias Tars.Event
  alias Tars.LLM.Config
  alias Tars.Scope
  alias Tars.Subagent
  alias Tars.Test.EchoTool
  alias Tars.Test.LLMStub

  setup :verify_on_exit!

  setup do
    agent_id = make_ref()
    :ok = Event.Bus.subscribe(agent_id)

    {:ok, agent_id: agent_id, scope: Scope.root(Config.new(), agent_id, name: "turn")}
  end

  defp researcher, do: Config.new(model_spec: {:test, model: "m"}, tools: [EchoTool])

  test "returns the delegate's final answer", %{scope: scope} do
    LLMStub.stream([LLMStub.final_answer("competitors charge $20/mo")])

    assert Subagent.run(scope, researcher(), "pricing?") == {:ok, "competitors charge $20/mo"}
  end

  test "runs under a child of the caller's span, on the caller's agent", %{scope: scope} do
    LLMStub.stream([LLMStub.final_answer("done")])

    {:ok, _text} = Subagent.run(scope, researcher(), "pricing?", name: "researcher")

    assert_receive %Event{payload: {:result, "result"}} = event

    refute Event.root?(event)
    assert event.source.agent_id == scope.source.agent_id
    assert event.source.trace.trace_id == scope.source.trace.trace_id
    assert event.source.trace.parent_span_id == scope.source.trace.span_id
    assert event.source.trace.name == "researcher"
  end

  test "runs with the delegate's tools, not the caller's", %{scope: scope} do
    test_pid = self()

    stub(ReqLLM, :stream_text, fn _model, _context, opts ->
      send(test_pid, {:tools, Enum.map(opts[:tools], & &1.name)})
      {:ok, :streamed}
    end)

    stub(ReqLLM.StreamResponse, :process_stream, fn :streamed, _opts ->
      {:ok, LLMStub.final_answer("done")}
    end)

    assert scope.config.tools == []
    {:ok, _text} = Subagent.run(scope, researcher(), "pricing?")

    assert_receive {:tools, ["echo"]}
  end

  test "the prompt is the delegate's whole conversation", %{scope: scope} do
    test_pid = self()

    stub(ReqLLM, :stream_text, fn _model, context, _opts ->
      send(test_pid, {:context, Enum.map(context.messages, & &1.role)})
      {:ok, :streamed}
    end)

    stub(ReqLLM.StreamResponse, :process_stream, fn :streamed, _opts ->
      {:ok, LLMStub.final_answer("done")}
    end)

    {:ok, _text} = Subagent.run(scope, researcher(), "pricing?")

    assert_receive {:context, [:user]}
  end

  test "a failed turn is reported to the caller", %{scope: scope} do
    stub(ReqLLM, :stream_text, fn _model, _context, _opts -> {:error, :rate_limited} end)

    assert {result, _log} =
             ExUnit.CaptureLog.with_log(fn -> Subagent.run(scope, researcher(), "pricing?") end)

    assert result == {:error, :rate_limited}
  end

  test "a turn that produced no text answers empty rather than failing", %{scope: scope} do
    LLMStub.stream([LLMStub.final_answer("")])

    assert Subagent.run(scope, researcher(), "pricing?") == {:ok, ""}
  end
end
