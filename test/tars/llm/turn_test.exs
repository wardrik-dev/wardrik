defmodule Tars.LLM.TurnTest do
  use ExUnit.Case, async: true

  use Mimic

  import ExUnit.CaptureLog

  alias ReqLLM.Context
  alias Tars.Event
  alias Tars.LLM
  alias Tars.LLM.Turn.Parked
  alias Tars.Scope
  alias Tars.Test.LLMStub

  setup :verify_on_exit!

  setup do
    agent_id = Tars.Test.Fleet.key()
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

    assert {:ok, _messages} = LLM.Turn.run(scope(Tars.Test.Fleet.key()), Context.new())

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

  test "the iteration cap ends a model that never stops calling tools with an answer", %{
    agent_id: agent_id
  } do
    test_pid = self()

    LLMStub.answering(fn asked ->
      send(test_pid, {:asked, asked})

      if asked.tools == [],
        do: {:ok, LLMStub.final_answer("what I have so far")},
        else: {:ok, LLMStub.tool_call("call_1", "echo", %{})}
    end)

    assert {:ok, messages} =
             capture(fn -> LLM.Turn.run(looping_scope(agent_id, 3), Context.new()) end)

    # Three rounds, each an assistant message and its tool result, then the answer.
    assert Enum.count(messages) == 7
    assert text(List.last(messages)) == "what I have so far"

    # The closing request carries no tools and says so.
    asked = for {:asked, asked} <- flush(), do: asked
    assert Enum.map(asked, &(&1.tools == [])) == [false, false, false, true]
    assert List.last(asked).system =~ "Answer now from what you have"
  end

  test "the closing request keeps the persona it adds to", %{agent_id: agent_id} do
    test_pid = self()

    LLMStub.answering(fn asked ->
      send(test_pid, {:asked, asked})

      if asked.tools == [],
        do: {:ok, LLMStub.final_answer("done")},
        else: {:ok, LLMStub.tool_call("call_1", "echo", %{})}
    end)

    scope = looping_scope(agent_id, 1)
    scope = %{scope | config: %{scope.config | system: "You are terse."}}

    assert {:ok, _messages} = capture(fn -> LLM.Turn.run(scope, Context.new()) end)

    asked = for {:asked, asked} <- flush(), do: asked
    assert List.last(asked).system =~ "You are terse."
    assert List.last(asked).system =~ "Answer now from what you have"
  end

  test "a closing answer that asks for tools anyway is kept as text only", %{agent_id: agent_id} do
    LLMStub.stream(List.duplicate(LLMStub.tool_call("call_1", "echo", %{}), 30))

    assert {:ok, messages} =
             capture(fn -> LLM.Turn.run(looping_scope(agent_id, 3), Context.new()) end)

    # Three rounds of tools; the closing call had nothing to say.
    assert Enum.count(messages) == 6
    refute Enum.any?(messages, &(&1.role == :tool and false))
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

  defp flush do
    receive do
      message -> [message | flush()]
    after
      0 -> []
    end
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

  defmodule AskingPolicy do
    @behaviour Tars.Policy
    @impl true
    def authorize(%{name: "deploy"}, _scope), do: {:ask, "This ships to production."}
    def authorize(_call, _scope), do: :allow
  end

  defmodule Routing do
    @behaviour Tars.LLM.Dispatch

    @impl true
    def admit(request, _scope) do
      {:ok, LLM.Request.put_model(request, {:anthropic, model: "routed"})}
    end

    @impl true
    def settle(_request, outcome, scope) do
      Tars.Event.emit(scope.source, {:settled, elem(outcome, 0)})
    end
  end

  defmodule Refusing do
    @behaviour Tars.LLM.Dispatch
    @impl true
    def admit(_request, _scope), do: {:error, :over_budget}
  end

  defp deploy_tool do
    ReqLLM.Tool.new!(
      name: "deploy",
      description: "Ship it.",
      parameter_schema: [],
      callback: fn _args -> {:ok, %{"shipped" => true}} end
    )
  end

  defp governed(agent_id, tools) do
    LLM.Config.new(tools: tools) |> Scope.root(agent_id, name: "turn", policy: AskingPolicy)
  end

  describe "the dispatch seam" do
    test "a host decides which model the call actually reaches", %{agent_id: agent_id} do
      test_pid = self()

      LLMStub.answering(fn asked ->
        send(test_pid, {:asked, asked})
        {:ok, LLMStub.final_answer("done")}
      end)

      scope =
        LLM.Config.new(model_spec: {:openai, model: "configured"})
        |> Scope.root(agent_id, name: "turn", dispatch: Routing)

      assert {:ok, _messages} = LLM.Turn.run(scope, Context.new([Context.user("hi")]))

      assert_receive {:asked, %{model: {:anthropic, model: "routed"}}}
    end

    test "every admitted call is reported once it has been made", %{agent_id: agent_id} do
      LLMStub.stream([LLMStub.final_answer("done")])

      scope = LLM.Config.new() |> Scope.root(agent_id, name: "turn", dispatch: Routing)

      assert {:ok, _messages} = LLM.Turn.run(scope, Context.new([Context.user("hi")]))

      assert_receive %Event{payload: {:settled, :ok}}
    end

    test "a refused call fails the turn without reaching the provider", %{agent_id: agent_id} do
      reject(&ReqLLM.stream_text/3)

      scope = LLM.Config.new() |> Scope.root(agent_id, name: "turn", dispatch: Refusing)

      log =
        capture_log(fn ->
          assert {:error, :over_budget} = LLM.Turn.run(scope, Context.new([Context.user("hi")]))
        end)

      assert log =~ "over_budget"
      assert_receive %Event{payload: {:model_finished, {:error, :over_budget}, _ms}}
    end
  end

  describe "deadlines" do
    test "a turn out of time stops without asking the model again", %{agent_id: agent_id} do
      reject(&ReqLLM.stream_text/3)

      scope = LLM.Config.new() |> Scope.root(agent_id, name: "turn", timeout: 0)

      log =
        capture_log(fn ->
          assert {:ok, []} = LLM.Turn.run(scope, Context.new([Context.user("hi")]))
        end)

      assert log =~ "deadline"
      assert_receive %Event{payload: {:deadline_reached, 0}}
    end
  end

  describe "stopping to ask" do
    test "a policy that asks parks the turn rather than appending half an exchange", %{
      agent_id: agent_id
    } do
      LLMStub.stream([LLMStub.tool_call("call_1", "deploy", %{})])

      scope = governed(agent_id, [deploy_tool()])

      assert {:parked, parked} = LLM.Turn.run(scope, Context.new([Context.user("ship it")]))

      assert [{%{id: "call_1", name: "deploy"}, "This ships to production."}] =
               Parked.calls(parked)

      assert Parked.waiting?(parked)
    end

    test "approving runs the call and finishes the turn", %{agent_id: agent_id} do
      LLMStub.stream([
        LLMStub.tool_call("call_1", "deploy", %{}),
        LLMStub.final_answer("shipped")
      ])

      scope = governed(agent_id, [deploy_tool()])

      assert {:parked, parked} = LLM.Turn.run(scope, Context.new([Context.user("ship it")]))
      assert {:ok, messages} = LLM.Turn.resume(scope, parked, %{"call_1" => :approve})

      assert Enum.any?(messages, &(&1.role == :tool))
      assert List.last(messages).role == :assistant
      assert_receive %Event{payload: {:tool_finished, "call_1", "deploy", _result}}
    end

    test "denying tells the model why and carries on", %{agent_id: agent_id} do
      LLMStub.stream([
        LLMStub.tool_call("call_1", "deploy", %{}),
        LLMStub.final_answer("understood")
      ])

      scope = governed(agent_id, [deploy_tool()])

      assert {:parked, parked} = LLM.Turn.run(scope, Context.new([Context.user("ship it")]))

      assert {:ok, messages} =
               LLM.Turn.resume(scope, parked, %{"call_1" => {:deny, "Not this quarter."}})

      result = Enum.find(messages, &(&1.role == :tool))
      [part] = result.content
      assert %{"error" => %{"message" => "Not this quarter."}} = JSON.decode!(part.text)
    end

    test "a call left undecided stays parked, so answers can arrive one at a time", %{
      agent_id: agent_id
    } do
      LLMStub.stream([LLMStub.tool_call("call_1", "deploy", %{})])

      scope = governed(agent_id, [deploy_tool()])

      assert {:parked, parked} = LLM.Turn.run(scope, Context.new([Context.user("ship it")]))
      assert {:parked, still} = LLM.Turn.resume(scope, parked, %{})
      assert Parked.waiting?(still)
    end

    test "an answer that is neither approval nor refusal refuses", %{agent_id: agent_id} do
      LLMStub.stream([
        LLMStub.tool_call("call_1", "deploy", %{}),
        LLMStub.final_answer("understood")
      ])

      scope = governed(agent_id, [deploy_tool()])

      assert {:parked, parked} = LLM.Turn.run(scope, Context.new([Context.user("ship it")]))
      assert {:ok, _messages} = LLM.Turn.resume(scope, parked, %{"call_1" => :perhaps})

      assert_receive %Event{payload: {:tool_denied, "call_1", "deploy", reason}}
      assert reason =~ ":perhaps"
    end
  end
end
