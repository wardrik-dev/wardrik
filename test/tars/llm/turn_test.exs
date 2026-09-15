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

  test "generation options reach the provider", %{agent_id: agent_id} do
    test_pid = self()

    Mimic.stub(ReqLLM, :stream_text, fn _model, _context, opts ->
      send(test_pid, {:opts, opts})
      {:ok, :streamed}
    end)

    Mimic.stub(ReqLLM.StreamResponse, :process_stream, fn :streamed, _opts ->
      {:ok, LLMStub.final_answer("hi")}
    end)

    config =
      LLM.Config.new(
        generation: [max_tokens: 8_000, provider_options: [thinking: %{type: "disabled"}]]
      )

    LLM.Turn.run(Scope.root(config, agent_id, name: "turn"), Context.new())

    assert_receive {:opts, opts}
    assert opts[:max_tokens] == 8_000
    assert opts[:provider_options] == [thinking: %{type: "disabled"}]
  end

  test "tools and the persona are not overridable through generation", %{agent_id: agent_id} do
    test_pid = self()

    Mimic.stub(ReqLLM, :stream_text, fn _model, _context, opts ->
      send(test_pid, {:opts, opts})
      {:ok, :streamed}
    end)

    Mimic.stub(ReqLLM.StreamResponse, :process_stream, fn :streamed, _opts ->
      {:ok, LLMStub.final_answer("hi")}
    end)

    config =
      LLM.Config.new(
        system: "the real persona",
        tools: [Tars.Test.EchoTool],
        generation: [tools: [], system_prompt: "an impostor"]
      )

    LLM.Turn.run(Scope.root(config, agent_id, name: "turn"), Context.new())

    assert_receive {:opts, opts}
    assert opts[:system_prompt] == "the real persona"
    assert Enum.map(opts[:tools], & &1.name) == ["echo"]
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
    LLMStub.stream(List.duplicate(LLMStub.tool_call("call_1", "echo", %{}), 30))

    assert {:ok, messages} =
             capture(fn -> LLM.Turn.run(looping_scope(agent_id, 3), Context.new()) end)

    # Three iterations, each appending an assistant message and its tool result.
    assert Enum.count(messages) == 6
  end

  test "the cap is a backstop a deployment can lift", %{agent_id: agent_id} do
    LLMStub.stream(
      List.duplicate(LLMStub.tool_call("call_1", "echo", %{}), 4) ++
        [LLMStub.final_answer("done")]
    )

    assert {:ok, messages} = LLM.Turn.run(looping_scope(agent_id, :infinity), Context.new())

    # Four rounds of tools, then the answer — none of it cut short.
    assert Enum.count(messages) == 9
  end

  describe "yield" do
    test "stops the turn at the next boundary, keeping what it has", %{agent_id: agent_id} do
      LLMStub.stream(List.duplicate(LLMStub.tool_call("call_1", "echo", %{}), 5))

      :ok = LLM.Turn.yield(self())

      assert {:ok, messages} = LLM.Turn.run(looping_scope(agent_id, :infinity), Context.new())

      # One round only: the assistant's tool call and its result.
      assert Enum.count(messages) == 2
    end

    test "never lands between a tool call and its result", %{agent_id: agent_id} do
      LLMStub.stream(List.duplicate(LLMStub.tool_call("call_1", "echo", %{}), 5))

      :ok = LLM.Turn.yield(self())

      {:ok, messages} = LLM.Turn.run(looping_scope(agent_id, :infinity), Context.new())

      assert Enum.map(messages, & &1.role) == [:assistant, :tool]
    end

    test "a turn that finishes first is unaffected", %{agent_id: agent_id} do
      LLMStub.stream([LLMStub.final_answer("done")])

      :ok = LLM.Turn.yield(self())

      assert {:ok, [_message]} = LLM.Turn.run(scope(agent_id), Context.new())

      # Unread, so it is still here for whoever looks next.
      assert_received :yield
    end
  end

  describe "interrupt" do
    test "stops a response that is still arriving and keeps what streamed", %{
      agent_id: agent_id
    } do
      Mimic.stub(ReqLLM, :stream_text, fn _model, _context, _opts -> {:ok, :streamed} end)

      Mimic.stub(ReqLLM.StreamResponse, :process_stream, fn :streamed, opts ->
        opts[:on_result].("half a th")
        opts[:on_chunk].(%{type: :content})
        opts[:on_result].("ought that never lands")
        opts[:on_chunk].(%{type: :content})

        {:ok, LLMStub.final_answer("the whole thing")}
      end)

      :ok = LLM.Turn.interrupt(self())

      assert {:ok, [message]} = LLM.Turn.run(scope(agent_id), Context.new())

      assert text(message) == "half a th"
      refute text(message) =~ "never lands"
    end

    test "an interrupt with nothing streamed yet appends nothing", %{agent_id: agent_id} do
      Mimic.stub(ReqLLM, :stream_text, fn _model, _context, _opts -> {:ok, :streamed} end)

      Mimic.stub(ReqLLM.StreamResponse, :process_stream, fn :streamed, opts ->
        opts[:on_chunk].(%{type: :content})
        {:ok, LLMStub.final_answer("unreachable")}
      end)

      :ok = LLM.Turn.interrupt(self())

      assert {:ok, []} = LLM.Turn.run(scope(agent_id), Context.new())
    end

    test "the model request is reported as having failed", %{agent_id: agent_id} do
      Mimic.stub(ReqLLM, :stream_text, fn _model, _context, _opts -> {:ok, :streamed} end)

      Mimic.stub(ReqLLM.StreamResponse, :process_stream, fn :streamed, opts ->
        opts[:on_chunk].(%{type: :content})
        {:ok, LLMStub.final_answer("unreachable")}
      end)

      :ok = LLM.Turn.interrupt(self())
      LLM.Turn.run(scope(agent_id), Context.new())

      assert_receive %Event{payload: {:model_finished, {:error, :interrupted}, _ms}}
    end

    # A provider that reports no chunks gives the stream no chance to notice, so
    # the interrupt is read at the boundary instead — the same place `:yield`
    # is read.
    test "also stops at an iteration boundary, like a yield", %{agent_id: agent_id} do
      Mimic.stub(ReqLLM, :stream_text, fn _model, _context, _opts -> {:ok, :streamed} end)

      Mimic.stub(ReqLLM.StreamResponse, :process_stream, fn :streamed, _opts ->
        {:ok, LLMStub.tool_call("call_1", "echo", %{})}
      end)

      :ok = LLM.Turn.interrupt(self())

      assert {:ok, messages} = LLM.Turn.run(looping_scope(agent_id, :infinity), Context.new())

      assert Enum.map(messages, & &1.role) == [:assistant, :tool]
    end
  end

  defp text(message) do
    message.content
    |> Enum.filter(&(&1.type == :text))
    |> Enum.map_join(& &1.text)
  end

  defp looping_scope(agent_id, max_iterations) do
    tool = ReqLLM.Tool.new!(name: "echo", description: "echo", callback: fn i -> {:ok, i} end)

    [tools: [tool], max_iterations: max_iterations]
    |> LLM.Config.new()
    |> Scope.root(agent_id, name: "turn")
  end

  defp capture(fun) do
    {result, _log} = ExUnit.CaptureLog.with_log(fun)
    result
  end
end
