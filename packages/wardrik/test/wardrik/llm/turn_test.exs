defmodule Wardrik.LLM.TurnTest do
  use ExUnit.Case, async: true

  use Mimic

  import ExUnit.CaptureLog

  alias ReqLLM.Context
  alias Wardrik.Call
  alias Wardrik.Event
  alias Wardrik.LLM
  alias Wardrik.Scope
  alias Wardrik.Test.LLMStub
  alias Wardrik.Tool.Result

  # A turn run or resumed through its token, as a turn under `scope` is.
  defp run(scope, context), do: scope |> LLM.Turn.new(context) |> LLM.Turn.run()

  defp resume(scope, turn, decisions),
    do: turn |> LLM.Turn.under(scope) |> LLM.Turn.resume(decisions)

  setup :verify_on_exit!

  setup do
    agent_id = Wardrik.Test.Fleet.id()
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

      assert %LLM.Turn{state: :done, messages: messages} =
               run(scope, Context.new([Context.user("hi")]))

      assert_receive {:asked, %{system: "You answer briefly."}}
      refute Enum.any?(messages, &(&1.role == :system))
    end

    test "is left out entirely when a config has none", %{agent_id: agent_id} do
      test_pid = self()

      LLMStub.answering(fn asked ->
        send(test_pid, {:asked, asked})
        {:ok, LLMStub.final_answer("done")}
      end)

      assert %LLM.Turn{state: :done, messages: _messages} = run(scope(agent_id), Context.new())

      assert_receive {:asked, %{system: nil}}
    end
  end

  test "a final answer terminates the loop and returns the assistant message", %{
    agent_id: agent_id
  } do
    LLMStub.stream([LLMStub.final_answer("hello")])

    assert %LLM.Turn{state: :done, messages: [message]} = run(scope(agent_id), Context.new())
    assert message.role == :assistant
  end

  test "tool calls loop once, then terminate on the final answer", %{agent_id: agent_id} do
    tool = ReqLLM.Tool.new!(name: "echo", description: "echo", callback: fn i -> {:ok, i} end)

    LLMStub.stream([
      LLMStub.tool_call("call_1", "echo", %{"input" => "hi"}),
      LLMStub.final_answer("done")
    ])

    context = Context.new([Context.user("hi")])

    assert %LLM.Turn{state: :done, messages: messages} = run(scope(agent_id, [tool]), context)

    # assistant(tool_use) -> tool(result) -> assistant(final), in order, and the
    # pre-existing user message is NOT re-reported: this is a delta.
    assert Enum.map(messages, & &1.role) == [:assistant, :tool, :assistant]
    assert_receive %Event{payload: %Event.ToolStarted{call_id: "call_1", name: "echo"}}

    assert_receive %Event{
      payload: %Event.ToolFinished{
        call_id: "call_1",
        name: "echo",
        result: {:ok, %{"input" => "hi"}}
      }
    }
  end

  test "stream callbacks are published as events for the agent", %{agent_id: agent_id} do
    :ok = Event.Bus.unsubscribe(agent_id)
    :ok = Event.Bus.subscribe(agent_id, level: :raw)
    LLMStub.stream([LLMStub.final_answer("hello")])

    assert %LLM.Turn{state: :done, messages: _messages} = run(scope(agent_id), Context.new())

    assert_receive %Event{payload: %Event.Chunk{chunk: "chunk"}}
    assert_receive %Event{payload: %Event.Meta{chunk: %{tokens: 1}}}
    assert_receive %Event{payload: %Event.Thinking{text: "thinking"}}
    assert_receive %Event{payload: %Event.Result{text: "result"}}
    assert_receive %Event{payload: %Event.ToolCall{call: %{name: "echo"}}}
  end

  test "the model request announces both ends", %{agent_id: agent_id} do
    LLMStub.stream([LLMStub.final_answer("hello")])

    assert %LLM.Turn{state: :done, messages: _messages} = run(scope(agent_id), Context.new())

    assert_receive %Event{payload: %Event.ModelStarted{}}
    assert_receive %Event{payload: %Event.ModelFinished{outcome: :ok}}
  end

  describe "what a call cost" do
    defp used(response, usage), do: %{response | usage: usage}

    defp priced_scope(agent_id, model_spec, tools \\ []) do
      [model_spec: model_spec, tools: tools]
      |> LLM.Config.new()
      |> Scope.root(agent_id, name: "turn")
    end

    test "is the provider's figure where it reports one", %{agent_id: agent_id} do
      usage = %{input_tokens: 10, output_tokens: 5, total_cost: 0.0123}
      LLMStub.stream([used(LLMStub.final_answer("hi"), usage)])

      run(scope(agent_id), Context.new())

      assert_receive %Event{
        payload: %Event.ModelFinished{outcome: :ok, cost: %{micro_usd: 12_300, source: :provider}}
      }
    end

    test "is the tokens at the catalog's prices otherwise", %{agent_id: agent_id} do
      spec = "anthropic:claude-sonnet-5"
      usage = %{input_tokens: 10_000, output_tokens: 2_000}
      LLMStub.stream([used(LLMStub.final_answer("hi"), usage)])

      run(priced_scope(agent_id, spec), Context.new())

      micro_usd = LLM.Cost.micro(LLM.Cost.of(spec, usage))
      assert micro_usd > 0

      assert_receive %Event{
        payload: %Event.ModelFinished{
          outcome: :ok,
          cost: %{micro_usd: ^micro_usd, source: :catalog}
        }
      }
    end

    test "is nil for a model nobody prices", %{agent_id: agent_id} do
      LLMStub.stream([used(LLMStub.final_answer("hi"), %{input_tokens: 10, output_tokens: 5})])

      capture_log(fn -> run(priced_scope(agent_id, "nowhere:no-such-model"), Context.new()) end)

      assert_receive %Event{
        payload: %Event.ModelFinished{outcome: :ok, response: %ReqLLM.Response{}, cost: nil}
      }
    end

    test "is what the config lists for a tool that says nothing, and what a tool says wins",
         %{agent_id: agent_id} do
      tool = fn name, answer ->
        Wardrik.Tool.new!(
          name: name,
          description: "Does something.",
          parameter_schema: [],
          run: fn _input, _context -> answer end
        )
      end

      tools = [
        tool.("listed", Result.ok(%{})),
        tool.("failing", {:error, "It broke."}),
        tool.("saying", Result.ok(%{}, cost: 0.002))
      ]

      LLMStub.stream([
        LLMStub.tool_call("call_1", "listed", %{}),
        LLMStub.tool_call("call_2", "failing", %{}),
        LLMStub.tool_call("call_3", "saying", %{}),
        LLMStub.final_answer("done")
      ])

      [tools: tools, tool_prices: %{"listed" => 0.01, "fail*" => 0.003, "*" => 0.5}]
      |> LLM.Config.new()
      |> Scope.root(agent_id, name: "turn")
      |> run(Context.new())

      assert_receive %Event{
        payload: %Event.ToolFinished{call_id: "call_1", cost: %{micro_usd: 10_000}}
      }

      assert_receive %Event{
        payload: %Event.ToolFinished{
          call_id: "call_2",
          result: {:error, _},
          cost: %{micro_usd: 3_000}
        }
      }

      assert_receive %Event{
        payload: %Event.ToolFinished{call_id: "call_3", cost: %{micro_usd: 2_000}}
      }
    end

    test "is what a failed call says it cost", %{agent_id: agent_id} do
      tool =
        Wardrik.Tool.new!(
          name: "charge",
          description: "Fails, and is charged.",
          parameter_schema: [],
          run: fn _input, _context -> {:error, "Declined.", cost: 0.25} end
        )

      LLMStub.stream([LLMStub.tool_call("call_1", "charge", %{}), LLMStub.final_answer("done")])

      run(scope(agent_id, [tool]), Context.new())

      assert_receive %Event{
        payload: %Event.ToolFinished{
          call_id: "call_1",
          name: "charge",
          result: {:error, "Declined."},
          served_by: nil,
          cost: %{micro_usd: 250_000, source: :tool}
        }
      }
    end

    test "is what a tool says a call cost", %{agent_id: agent_id} do
      tool =
        Wardrik.Tool.new!(
          name: "search",
          description: "Searches, at a price.",
          parameter_schema: [q: [type: :string]],
          run: fn _input, _context -> Result.ok(%{"hits" => 1}, cost: 0.004) end
        )

      LLMStub.stream([
        LLMStub.tool_call("call_1", "search", %{"q" => "x"}),
        LLMStub.final_answer("done")
      ])

      run(scope(agent_id, [tool]), Context.new())

      assert_receive %Event{
        payload: %Event.ToolFinished{
          call_id: "call_1",
          name: "search",
          result: {:ok, %{"ok" => true}},
          served_by: nil,
          cost: %{micro_usd: 4_000, source: :tool}
        }
      }
    end
  end

  test "a failed request is announced before the turn gives up", %{agent_id: agent_id} do
    Mimic.stub(ReqLLM, :stream_text, fn _model, _context, _opts -> {:error, :rate_limited} end)

    {_result, _log} =
      ExUnit.CaptureLog.with_log(fn -> run(scope(agent_id), Context.new()) end)

    assert_receive %Event{payload: %Event.ModelStarted{}}

    assert_receive %Event{
      payload: %Event.ModelFinished{outcome: {:error, :rate_limited}}
    }
  end

  describe "a model call that fails before it answers" do
    defp retrying(agent_id, retries) do
      [retries: retries] |> LLM.Config.new() |> Scope.root(agent_id, name: "turn")
    end

    defp answering do
      stub(ReqLLM, :stream_text, fn _model, _context, _opts -> {:ok, :streamed} end)

      stub(ReqLLM.StreamResponse, :process_stream, fn :streamed, opts ->
        opts[:on_chunk].(%{type: :content})
        {:ok, LLMStub.final_answer("done")}
      end)
    end

    test "is asked again after a wait, and the turn answers", %{agent_id: agent_id} do
      answering()
      expect(ReqLLM, :stream_text, fn _model, _context, _opts -> {:error, :timeout} end)

      capture_log(fn ->
        assert %LLM.Turn{state: :done, messages: [%{role: :assistant}]} =
                 run(retrying(agent_id, [0]), Context.new([Context.user("hi")]))
      end)

      assert_receive %Event{payload: %Event.ModelStarted{}}

      assert_receive %Event{
        payload: %Event.ModelFinished{outcome: {:error, :timeout}}
      }

      assert_receive %Event{payload: %Event.ModelStarted{}}
      assert_receive %Event{payload: %Event.ModelFinished{outcome: :ok}}
    end

    test "fails the turn once its retries are spent", %{agent_id: agent_id} do
      expect(ReqLLM, :stream_text, 3, fn _model, _context, _opts -> {:error, :timeout} end)

      log =
        capture_log(fn ->
          assert %LLM.Turn{state: :failed, error: :timeout} =
                   run(retrying(agent_id, [0, 0]), Context.new([Context.user("hi")]))
        end)

      assert log =~ "asking again in 0ms"
    end

    test "is not asked again for a reason that would fail the same way", %{agent_id: agent_id} do
      expect(ReqLLM, :stream_text, 1, fn _model, _context, _opts -> {:error, :rate_limited} end)

      capture_log(fn ->
        assert %LLM.Turn{state: :failed, error: :rate_limited} =
                 run(retrying(agent_id, [0]), Context.new([Context.user("hi")]))
      end)
    end

    test "is not asked again once the provider has begun to answer", %{agent_id: agent_id} do
      expect(ReqLLM, :stream_text, 1, fn _model, _context, _opts -> {:ok, :streamed} end)

      stub(ReqLLM.StreamResponse, :process_stream, fn :streamed, opts ->
        opts[:on_chunk].(%{type: :content})
        {:error, :closed}
      end)

      capture_log(fn ->
        assert %LLM.Turn{state: :failed, error: :closed} =
                 run(retrying(agent_id, [0]), Context.new([Context.user("hi")]))
      end)
    end

    test "stops waiting when the turn is interrupted", %{agent_id: agent_id} do
      expect(ReqLLM, :stream_text, 1, fn _model, _context, _opts -> {:error, :timeout} end)
      :ok = LLM.Turn.interrupt(self())

      capture_log(fn ->
        assert %LLM.Turn{state: :done, messages: []} =
                 run(
                   retrying(agent_id, [:timer.minutes(10)]),
                   Context.new([Context.user("hi")])
                 )
      end)
    end
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

    run(Scope.root(config, agent_id, name: "turn"), Context.new())

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
        tools: [Wardrik.Test.EchoTool],
        generation: [tools: [], system_prompt: "an impostor"]
      )

    run(Scope.root(config, agent_id, name: "turn"), Context.new())

    assert_receive {:opts, opts}
    assert opts[:system_prompt] == "the real persona"
    assert Enum.map(opts[:tools], & &1.name) == ["echo"]
  end

  test "stream events are not published to other agents", %{agent_id: agent_id} do
    LLMStub.stream([LLMStub.final_answer("hello")])

    assert %LLM.Turn{state: :done, messages: _messages} =
             run(scope(Wardrik.Test.Fleet.id()), Context.new())

    refute_receive %Event{}
    assert Event.Bus.subscribers(agent_id) == [self()]
  end

  test "a stream error aborts the turn", %{agent_id: agent_id} do
    stub(ReqLLM, :stream_text, fn _model, _context, _opts -> {:error, :rate_limited} end)

    assert %LLM.Turn{state: :failed, error: :rate_limited} =
             capture(fn -> run(scope(agent_id), Context.new()) end)
  end

  test "a response with no assistant message falls back to the classified text", %{
    agent_id: agent_id
  } do
    LLMStub.stream([LLMStub.response(nil, :stop)])

    assert %LLM.Turn{state: :done, messages: [message]} = run(scope(agent_id), Context.new())
    assert message.role == :assistant
  end

  test "provider-executed calls are not run as tools and end the turn", %{agent_id: agent_id} do
    call = ReqLLM.ToolCall.new("call_1", "web_search", "{}")
    builtin = %{call | function: Map.put(call.function, :builtin?, true)}

    LLMStub.stream([LLMStub.response(Context.assistant("", tool_calls: [builtin]), :tool_calls)])

    assert %LLM.Turn{state: :done, messages: [message]} = run(scope(agent_id), Context.new())
    assert message.role == :assistant
    refute_receive %Event{payload: %Event.ToolStarted{}}
  end

  test "an unpairable tool exchange aborts rather than looping", %{agent_id: agent_id} do
    tool = ReqLLM.Tool.new!(name: "echo", description: "echo", callback: fn i -> {:ok, i} end)

    # An empty call id fails ToolExchange's `valid_call?/1`, so results can
    # never be matched back to the assistant message.
    LLMStub.stream([LLMStub.tool_call("", "echo", %{})])

    assert %LLM.Turn{state: :failed, error: _reason} =
             capture(fn -> run(scope(agent_id, [tool]), Context.new()) end)
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

    assert %LLM.Turn{state: :done, messages: messages} =
             capture(fn -> run(looping_scope(agent_id, 3), Context.new()) end)

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

    assert %LLM.Turn{state: :done, messages: _messages} =
             capture(fn -> run(scope, Context.new()) end)

    asked = for {:asked, asked} <- flush(), do: asked
    assert List.last(asked).system =~ "You are terse."
    assert List.last(asked).system =~ "Answer now from what you have"
  end

  test "a closing answer that asks for tools anyway is kept as text only", %{agent_id: agent_id} do
    LLMStub.stream(List.duplicate(LLMStub.tool_call("call_1", "echo", %{}), 30))

    assert %LLM.Turn{state: :done, messages: messages} =
             capture(fn -> run(looping_scope(agent_id, 3), Context.new()) end)

    # Three rounds of tools; the closing call had nothing to say.
    assert Enum.count(messages) == 6
    refute Enum.any?(messages, &(&1.role == :tool and false))
  end

  test "the cap is a backstop a deployment can lift", %{agent_id: agent_id} do
    LLMStub.stream(
      List.duplicate(LLMStub.tool_call("call_1", "echo", %{}), 4) ++
        [LLMStub.final_answer("done")]
    )

    assert %LLM.Turn{state: :done, messages: messages} =
             run(looping_scope(agent_id, :infinity), Context.new())

    # Four rounds of tools, then the answer — none of it cut short.
    assert Enum.count(messages) == 9
  end

  describe "yield" do
    test "stops the turn at the next boundary, keeping what it has", %{agent_id: agent_id} do
      LLMStub.stream(List.duplicate(LLMStub.tool_call("call_1", "echo", %{}), 5))

      :ok = LLM.Turn.yield(self())

      assert %LLM.Turn{state: :done, messages: messages} =
               run(looping_scope(agent_id, :infinity), Context.new())

      # One round only: the assistant's tool call and its result.
      assert Enum.count(messages) == 2
    end

    test "never lands between a tool call and its result", %{agent_id: agent_id} do
      LLMStub.stream(List.duplicate(LLMStub.tool_call("call_1", "echo", %{}), 5))

      :ok = LLM.Turn.yield(self())

      %LLM.Turn{state: :done, messages: messages} =
        run(looping_scope(agent_id, :infinity), Context.new())

      assert Enum.map(messages, & &1.role) == [:assistant, :tool]
    end

    test "a turn that finishes first is unaffected", %{agent_id: agent_id} do
      LLMStub.stream([LLMStub.final_answer("done")])

      :ok = LLM.Turn.yield(self())

      assert %LLM.Turn{state: :done, messages: [_message]} = run(scope(agent_id), Context.new())

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

      assert %LLM.Turn{state: :done, messages: [message]} = run(scope(agent_id), Context.new())

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

      assert %LLM.Turn{state: :done, messages: []} = run(scope(agent_id), Context.new())
    end

    test "the model request is reported as having failed", %{agent_id: agent_id} do
      Mimic.stub(ReqLLM, :stream_text, fn _model, _context, _opts -> {:ok, :streamed} end)

      Mimic.stub(ReqLLM.StreamResponse, :process_stream, fn :streamed, opts ->
        opts[:on_chunk].(%{type: :content})
        {:ok, LLMStub.final_answer("unreachable")}
      end)

      :ok = LLM.Turn.interrupt(self())
      run(scope(agent_id), Context.new())

      assert_receive %Event{
        payload: %Event.ModelFinished{outcome: {:error, :interrupted}}
      }
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

      assert %LLM.Turn{state: :done, messages: messages} =
               run(looping_scope(agent_id, :infinity), Context.new())

      assert Enum.map(messages, & &1.role) == [:assistant, :tool]
    end
  end

  defp text(message) do
    message.content
    |> Enum.filter(&(&1.type == :text))
    |> Enum.map_join(& &1.text)
  end

  describe "what the tools say first" do
    defmodule TellingSource do
      @behaviour Wardrik.Tool

      @impl true
      def tools(_argument), do: []

      @impl true
      def context(:own), do: "Your notes say the deploy is Friday."
      def context(:outside), do: {"A page you saved says to deploy now.", ["outside"]}
    end

    test "follows the persona in every request of the turn, the closing one too", %{
      agent_id: agent_id
    } do
      test_pid = self()

      LLMStub.answering(fn asked ->
        send(test_pid, {:asked, asked})

        if asked.tools == [],
          do: {:ok, LLMStub.final_answer("done")},
          else: {:ok, LLMStub.tool_call("call_1", "echo", %{})}
      end)

      scope = looping_scope(agent_id, 1)

      scope = %{
        scope
        | config: %{
            scope.config
            | system: "You are terse.",
              tools: [{TellingSource, :own} | scope.config.tools]
          }
      }

      assert %LLM.Turn{state: :done, preamble: "Your notes say the deploy is Friday."} =
               capture(fn -> run(scope, Context.new()) end)

      assert [first, closing] = for({:asked, asked} <- flush(), do: asked.system)
      assert first == "You are terse.\n\nYour notes say the deploy is Friday."
      assert String.starts_with?(closing, first <> "\n\n")
      assert closing =~ "Answer now from what you have"
    end

    test "is what the turn began with, when it is resumed under tools that say otherwise", %{
      agent_id: agent_id
    } do
      test_pid = self()

      LLMStub.answering(fn asked ->
        send(test_pid, {:asked, asked.system})
        asked_before = Process.get(:asked, 0)
        Process.put(:asked, asked_before + 1)

        if asked_before == 0,
          do: {:ok, LLMStub.tool_call("call_1", "deploy", %{})},
          else: {:ok, LLMStub.final_answer("done")}
      end)

      assert %LLM.Turn{state: :waiting} =
               parked =
               run(governed(agent_id, [{TellingSource, :own}, deploy_tool()]), Context.new())

      assert %LLM.Turn{state: :done} =
               resume(governed(agent_id, [deploy_tool()]), parked, %{"call_1" => :approve})

      assert for({:asked, system} <- flush(), do: system) ==
               List.duplicate("Your notes say the deploy is Friday.", 2)
    end

    test "labels the turn from its start where it came from outside", %{agent_id: agent_id} do
      LLMStub.stream([LLMStub.tool_call("call_1", "deploy", %{"target" => "prod"})])
      rules = [Wardrik.Hook.new("rules", Wardrik.Test.Tools.Rules, allow: ["deploy"])]

      scope =
        [tools: [{TellingSource, :outside}, Wardrik.Test.Tools.Deploy]]
        |> LLM.Config.new()
        |> Scope.root(agent_id, name: "turn", hooks: rules)

      assert %LLM.Turn{state: :waiting, labels: ["outside"]} = parked = run(scope, Context.new())

      assert [{%{id: "call_1", name: "deploy", labels: ["outside"]}, prompt}] =
               LLM.Turn.waiting(parked)

      assert prompt =~ "this run has read content from outside"
    end

    test "lets a gated call a rule allows after outside content go ahead, and labels the turn",
         %{agent_id: agent_id} do
      LLMStub.stream([
        LLMStub.tool_call("call_1", "deploy", %{"target" => "prod"}),
        LLMStub.final_answer("Deployed.")
      ])

      rules = [
        Wardrik.Hook.new("rules", Wardrik.Test.Tools.Rules,
          allow_after: %{"outside" => ["deploy"]}
        )
      ]

      scope =
        [tools: [{TellingSource, :outside}, Wardrik.Test.Tools.Deploy]]
        |> LLM.Config.new()
        |> Scope.root(agent_id, name: "turn", hooks: rules)

      assert %LLM.Turn{state: :done, labels: ["outside"]} = run(scope, Context.new())
    end

    test "carries from the start the labels of a scope that carries some already",
         %{agent_id: agent_id} do
      LLMStub.stream([LLMStub.tool_call("call_1", "deploy", %{"target" => "prod"})])

      rules = [Wardrik.Hook.new("rules", Wardrik.Test.Tools.Rules, allow: ["deploy"])]

      scope =
        [tools: [Wardrik.Test.Tools.Deploy]]
        |> LLM.Config.new()
        |> Scope.root(agent_id, name: "turn", hooks: rules)

      assert %LLM.Turn{state: :waiting, labels: ["outside"]} =
               parked = run(%{scope | labels: ["outside"]}, Context.new())

      assert [{%{id: "call_1"}, prompt}] = LLM.Turn.waiting(parked)
      assert prompt =~ "this run has read content from outside"
    end
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

  defmodule AskingHook do
    @behaviour Wardrik.Hook
    @impl true
    def init(_opts), do: nil
    @impl true
    def call(%Call{target: %Call.Tool{name: "deploy"}}, _value),
      do: {:ask, "This ships to production."}

    def call(_call, _value), do: :pass
  end

  defmodule DenyingHook do
    @behaviour Wardrik.Hook
    @impl true
    def init(_opts), do: nil
    @impl true
    def call(%Call{target: %Call.Tool{name: "deploy"}}, _value), do: {:deny, "Frozen."}
    def call(_call, _value), do: :pass
  end

  # Asks about every model call, and remembers nothing.
  defmodule ModelAsker do
    @behaviour Wardrik.Hook
    @impl true
    def init(_opts), do: nil
    @impl true
    def call(%Call{target: %Call.Model{}}, _value), do: {:ask, "Use the model?"}
    def call(_call, _value), do: :pass
  end

  defmodule Routing do
    @behaviour Wardrik.LLM.Dispatch

    @impl true
    def admit(request, _scope, _test) do
      {:ok, LLM.Request.put_model(request, {:anthropic, model: "routed"})}
    end

    @impl true
    def settle(_request, outcome, _scope, test), do: send(test, {:settled, elem(outcome, 0)})
  end

  defmodule Refusing do
    @behaviour Wardrik.LLM.Dispatch
    @impl true
    def admit(_request, _scope), do: {:error, :over_budget}
  end

  defmodule Recording do
    @behaviour Wardrik.LLM.Dispatch

    @impl true
    def admit(request, _scope, _test), do: {:ok, request}

    @impl true
    def settle(_request, outcome, _scope, test), do: send(test, {:settled, outcome})
  end

  # A hook named with a value: the Agent holding the memo a person approved,
  # if one has been.
  defmodule Gate do
    @behaviour Wardrik.Hook

    @impl true
    def init(gate), do: gate

    @impl true
    def call(%Call{target: %Call.Model{}}, gate) do
      if Agent.get(gate, & &1), do: :pass, else: {:ask, "Spent $5.00 of $5.00 today.", :day}
    end

    @impl true
    def approved(_call, memo, gate), do: Agent.update(gate, fn _ -> memo end)
  end

  defp deploy_tool do
    ReqLLM.Tool.new!(
      name: "deploy",
      description: "Ship it.",
      parameter_schema: [],
      callback: fn _args -> {:ok, %{"shipped" => true}} end
    )
  end

  defp governed(agent_id, tools, hooks \\ [Wardrik.Hook.new("asking", AskingHook)]) do
    LLM.Config.new(tools: tools) |> Scope.root(agent_id, name: "turn", hooks: hooks)
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
        |> Scope.root(agent_id, name: "turn", dispatch: {Routing, self()})

      assert %LLM.Turn{state: :done, messages: _messages} =
               run(scope, Context.new([Context.user("hi")]))

      assert_receive {:asked, %{model: {:anthropic, model: "routed"}}}
    end

    test "every admitted call is reported once it has been made", %{agent_id: agent_id} do
      LLMStub.stream([LLMStub.final_answer("done")])

      scope = LLM.Config.new() |> Scope.root(agent_id, name: "turn", dispatch: {Routing, self()})

      assert %LLM.Turn{state: :done, messages: _messages} =
               run(scope, Context.new([Context.user("hi")]))

      assert_receive {:settled, :ok}
    end

    test "a stream that fails once the provider has begun to answer settles with what streamed",
         %{agent_id: agent_id} do
      Mimic.stub(ReqLLM, :stream_text, fn _model, _context, _opts -> {:ok, :streamed} end)

      Mimic.stub(ReqLLM.StreamResponse, :process_stream, fn :streamed, opts ->
        opts[:on_chunk].(%{type: :content})
        opts[:on_result].("half an ans")
        {:error, :closed}
      end)

      scope =
        LLM.Config.new() |> Scope.root(agent_id, name: "turn", dispatch: {Recording, self()})

      capture_log(fn ->
        assert %LLM.Turn{state: :failed, error: :closed} =
                 run(scope, Context.new([Context.user("hi")]))
      end)

      assert_receive {:settled, {:error, :closed, "half an ans"}}
    end

    test "a call that fails before the provider answers settles with no text", %{
      agent_id: agent_id
    } do
      Mimic.stub(ReqLLM, :stream_text, fn _model, _context, _opts -> {:error, :rate_limited} end)

      scope =
        LLM.Config.new() |> Scope.root(agent_id, name: "turn", dispatch: {Recording, self()})

      capture_log(fn ->
        assert %LLM.Turn{state: :failed, error: :rate_limited} =
                 run(scope, Context.new([Context.user("hi")]))
      end)

      assert_receive {:settled, {:error, :rate_limited}}
    end

    test "a refused call fails the turn without reaching the provider", %{agent_id: agent_id} do
      reject(&ReqLLM.stream_text/3)

      scope = LLM.Config.new() |> Scope.root(agent_id, name: "turn", dispatch: Refusing)

      log =
        capture_log(fn ->
          assert %LLM.Turn{state: :failed, error: :over_budget} =
                   run(scope, Context.new([Context.user("hi")]))
        end)

      assert log =~ "over_budget"

      assert_receive %Event{
        payload: %Event.ModelFinished{outcome: {:error, :over_budget}}
      }
    end
  end

  describe "a hook that asks about a model call" do
    setup %{agent_id: agent_id} do
      {:ok, gate} = Agent.start_link(fn -> nil end)
      hooks = [Wardrik.Hook.new("gate", Gate, gate)]
      %{scope: LLM.Config.new() |> Scope.root(agent_id, name: "turn", hooks: hooks), gate: gate}
    end

    test "stops the turn before the call, with the model call waiting", %{scope: scope} do
      reject(&ReqLLM.stream_text/3)

      assert %LLM.Turn{state: :waiting} = parked = run(scope, Context.new([Context.user("hi")]))

      assert LLM.Turn.model?(parked)

      assert [{%{name: "model", id: "model_" <> _id}, "Spent $5.00 of $5.00 today."}] =
               LLM.Turn.waiting(parked)

      refute_received %Event{payload: %Event.ModelStarted{}}
    end

    test "approving it makes the call, and tells the hook with its memo", %{
      scope: scope,
      gate: gate
    } do
      LLMStub.stream([LLMStub.final_answer("done")])

      %LLM.Turn{state: :waiting} = parked = run(scope, Context.new([Context.user("hi")]))
      [{call, _prompt}] = LLM.Turn.waiting(parked)

      assert %LLM.Turn{state: :done, messages: [answer]} =
               resume(scope, parked, %{call.id => :approve})

      assert answer.role == :assistant
      assert Agent.get(gate, & &1) == :day
    end

    test "an approved call is made without the hooks being asked again", %{agent_id: agent_id} do
      LLMStub.stream([LLMStub.final_answer("done")])

      scope = governed(agent_id, [], [Wardrik.Hook.new("asker", ModelAsker)])

      %LLM.Turn{state: :waiting} = parked = run(scope, Context.new([Context.user("hi")]))
      [{call, _prompt}] = LLM.Turn.waiting(parked)

      assert %LLM.Turn{state: :done, messages: [answer]} =
               resume(scope, parked, %{call.id => :approve})

      assert answer.role == :assistant
    end

    test "denying it ends the turn as a refusal", %{scope: scope} do
      reject(&ReqLLM.stream_text/3)

      %LLM.Turn{state: :waiting} = parked = run(scope, Context.new([Context.user("hi")]))
      [{call, _prompt}] = LLM.Turn.waiting(parked)

      assert %LLM.Turn{state: :failed, error: {:policy_denied, "Not today."}} =
               resume(scope, parked, %{call.id => {:deny, "Not today."}})

      assert Wardrik.Failure.classify({:policy_denied, "Not today."}) == :ceiling
    end

    test "with no decision for it, stays parked", %{scope: scope} do
      %LLM.Turn{state: :waiting} = parked = run(scope, Context.new([Context.user("hi")]))

      assert %LLM.Turn{state: :waiting} =
               ^parked = resume(scope, parked, %{"call_other" => :approve})
    end
  end

  describe "deadlines" do
    test "a turn out of time stops without asking the model again", %{agent_id: agent_id} do
      reject(&ReqLLM.stream_text/3)

      scope = LLM.Config.new() |> Scope.root(agent_id, name: "turn", timeout: 0)

      log =
        capture_log(fn ->
          assert %LLM.Turn{state: :done, messages: []} =
                   run(scope, Context.new([Context.user("hi")]))
        end)

      assert log =~ "deadline"
      assert_receive %Event{payload: %Event.DeadlineReached{message_count: 0}}
    end
  end

  describe "stopping to ask" do
    test "a hook that asks parks the turn rather than appending half an exchange", %{
      agent_id: agent_id
    } do
      LLMStub.stream([LLMStub.tool_call("call_1", "deploy", %{})])

      scope = governed(agent_id, [deploy_tool()])

      assert %LLM.Turn{state: :waiting} =
               parked = run(scope, Context.new([Context.user("ship it")]))

      assert [{%{id: "call_1", name: "deploy"}, "This ships to production."}] =
               LLM.Turn.waiting(parked)

      assert parked.state == :waiting
    end

    test "approving runs the call and finishes the turn", %{agent_id: agent_id} do
      LLMStub.stream([
        LLMStub.tool_call("call_1", "deploy", %{}),
        LLMStub.final_answer("shipped")
      ])

      scope = governed(agent_id, [deploy_tool()])

      assert %LLM.Turn{state: :waiting} =
               parked = run(scope, Context.new([Context.user("ship it")]))

      assert %LLM.Turn{state: :done, messages: messages} =
               resume(scope, parked, %{"call_1" => :approve})

      assert Enum.any?(messages, &(&1.role == :tool))
      assert List.last(messages).role == :assistant
      assert_receive %Event{payload: %Event.ToolFinished{call_id: "call_1", name: "deploy"}}
    end

    test "approving with a note hands the model the note beside the call's answer", %{
      agent_id: agent_id
    } do
      calls = for id <- ["call_1", "call_2"], do: ReqLLM.ToolCall.new(id, "deploy", "{}")

      LLMStub.stream([
        LLMStub.response(ReqLLM.Context.assistant("", tool_calls: calls), :tool_calls),
        LLMStub.final_answer("shipped")
      ])

      scope = governed(agent_id, [deploy_tool()])

      assert %LLM.Turn{state: :waiting} =
               parked = run(scope, Context.new([Context.user("ship it twice")]))

      assert %LLM.Turn{state: :done, messages: messages} =
               resume(scope, parked, %{
                 "call_1" => {:approve, " Only to staging. "},
                 "call_2" => {:approve, "  "}
               })

      [first, second] =
        for %{role: :tool, content: [part]} <- messages, do: JSON.decode!(part.text)

      assert first == %{"shipped" => true, "note" => "Only to staging."}
      assert second == %{"shipped" => true}
    end

    test "denying tells the model why and carries on", %{agent_id: agent_id} do
      LLMStub.stream([
        LLMStub.tool_call("call_1", "deploy", %{}),
        LLMStub.final_answer("understood")
      ])

      scope = governed(agent_id, [deploy_tool()])

      assert %LLM.Turn{state: :waiting} =
               parked = run(scope, Context.new([Context.user("ship it")]))

      assert %LLM.Turn{state: :done, messages: messages} =
               resume(scope, parked, %{"call_1" => {:deny, "Not this quarter."}})

      result = Enum.find(messages, &(&1.role == :tool))
      [part] = result.content
      assert %{"error" => %{"message" => "Not this quarter."}} = JSON.decode!(part.text)
    end

    test "a call left undecided stays parked, so answers can arrive one at a time", %{
      agent_id: agent_id
    } do
      LLMStub.stream([LLMStub.tool_call("call_1", "deploy", %{})])

      scope = governed(agent_id, [deploy_tool()])

      assert %LLM.Turn{state: :waiting} =
               parked = run(scope, Context.new([Context.user("ship it")]))

      assert %LLM.Turn{state: :waiting} = still = resume(scope, parked, %{})
      assert still.state == :waiting
    end

    test "an answer that is neither approval nor refusal refuses", %{agent_id: agent_id} do
      LLMStub.stream([
        LLMStub.tool_call("call_1", "deploy", %{}),
        LLMStub.final_answer("understood")
      ])

      scope = governed(agent_id, [deploy_tool()])

      assert %LLM.Turn{state: :waiting} =
               parked = run(scope, Context.new([Context.user("ship it")]))

      assert %LLM.Turn{state: :done, messages: _messages} =
               resume(scope, parked, %{"call_1" => :perhaps})

      assert_receive %Event{
        payload: %Event.ToolDenied{call_id: "call_1", name: "deploy", reason: reason}
      }

      assert reason =~ ":perhaps"
    end
  end

  describe "content from outside" do
    alias Wardrik.Test.Tools.Deploy
    alias Wardrik.Test.Tools.Fetch
    alias Wardrik.Test.Tools.Rules

    # A turn whose rules allow deploy by name, where deploy is gated.
    defp allowing_deploy(agent_id, rules \\ [allow: ["deploy"]]) do
      [tools: [Fetch, Deploy]]
      |> LLM.Config.new()
      |> Scope.root(agent_id, name: "turn", hooks: [Wardrik.Hook.new("rules", Rules, rules)])
    end

    test "a gated call a rule allows runs in a turn that has read nothing from outside", %{
      agent_id: agent_id
    } do
      LLMStub.stream([
        LLMStub.tool_call("call_1", "deploy", %{"target" => "prod"}),
        LLMStub.final_answer("deployed")
      ])

      assert %LLM.Turn{state: :done, labels: []} =
               run(allowing_deploy(agent_id), Context.new([Context.user("deploy")]))

      assert_receive %Event{payload: %Event.ToolFinished{call_id: "call_1", name: "deploy"}}
    end

    test "waits on a person once the turn has read content from outside, and keeps the label", %{
      agent_id: agent_id
    } do
      LLMStub.stream([
        LLMStub.tool_call("call_1", "fetch", %{"url" => "https://example.com"}),
        LLMStub.tool_call("call_2", "deploy", %{"target" => "prod"})
      ])

      assert %LLM.Turn{state: :waiting, labels: ["outside"]} =
               parked = run(allowing_deploy(agent_id), Context.new([Context.user("read it")]))

      assert [{%{id: "call_2", name: "deploy"}, prompt}] = LLM.Turn.waiting(parked)
      assert prompt =~ "this run has read content from outside"
      refute_received %Event{payload: %Event.ToolStarted{call_id: "call_2"}}

      assert %LLM.Turn{labels: ["outside"]} = LLM.Turn.under(parked, nil)
    end

    test "lets a rule that allows after outside content stand, and keeps the label",
         %{agent_id: agent_id} do
      LLMStub.stream([
        LLMStub.tool_call("call_1", "fetch", %{"url" => "https://example.com"}),
        LLMStub.tool_call("call_2", "deploy", %{"target" => "prod"}),
        LLMStub.final_answer("deployed")
      ])

      scope = allowing_deploy(agent_id, allow_after: %{"outside" => ["deploy"]})

      assert %LLM.Turn{state: :done, labels: ["outside"]} =
               run(scope, Context.new([Context.user("read it")]))

      assert_receive %Event{payload: %Event.ToolFinished{call_id: "call_2", name: "deploy"}}
    end
  end

  describe "resuming under other hooks" do
    test "a call the new hooks allow runs, whatever was decided", %{agent_id: agent_id} do
      LLMStub.stream([
        LLMStub.tool_call("call_1", "deploy", %{}),
        LLMStub.final_answer("shipped")
      ])

      %LLM.Turn{state: :waiting} =
        parked =
        run(governed(agent_id, [deploy_tool()]), Context.new([Context.user("ship")]))

      loosened = governed(agent_id, [deploy_tool()], [])

      assert %LLM.Turn{state: :done, messages: _messages} =
               resume(loosened, parked, %{"call_1" => {:deny, "Not now."}})

      assert_receive %Event{payload: %Event.ToolFinished{call_id: "call_1", name: "deploy"}}
    end

    test "a call the new hooks deny is refused, whatever was decided", %{agent_id: agent_id} do
      LLMStub.stream([
        LLMStub.tool_call("call_1", "deploy", %{}),
        LLMStub.final_answer("understood")
      ])

      %LLM.Turn{state: :waiting} =
        parked =
        run(governed(agent_id, [deploy_tool()]), Context.new([Context.user("ship")]))

      frozen =
        governed(agent_id, [deploy_tool()], [Wardrik.Hook.new("freeze", DenyingHook)])

      assert %LLM.Turn{state: :done, messages: _messages} =
               resume(frozen, parked, %{"call_1" => :approve})

      assert_receive %Event{
        payload: %Event.ToolDenied{call_id: "call_1", name: "deploy", reason: "Frozen."}
      }

      refute_received %Event{payload: %Event.ToolFinished{call_id: "call_1", name: "deploy"}}
    end

    test "a call the new hooks ask about waits again under them", %{agent_id: agent_id} do
      LLMStub.stream([LLMStub.tool_call("call_1", "deploy", %{})])

      old = [Wardrik.Hook.new("asking", AskingHook)]
      new = [Wardrik.Hook.new("asking-again", AskingHook)]

      %LLM.Turn{state: :waiting} =
        parked =
        run(
          governed(agent_id, [deploy_tool()], old),
          Context.new([Context.user("ship")])
        )

      scope = governed(agent_id, [deploy_tool()], new)

      assert %LLM.Turn{state: :waiting} = again = resume(scope, parked, %{"call_1" => :approve})
      assert again.revision == Wardrik.Hook.revision(new)
      assert [{%{id: "call_1"}, "This ships to production."}] = LLM.Turn.waiting(again)
      refute_received %Event{payload: %Event.ToolFinished{call_id: "call_1", name: "deploy"}}
    end

    test "a model call is asked about again", %{agent_id: agent_id} do
      LLMStub.stream([LLMStub.final_answer("done")])

      asking = governed(agent_id, [], [Wardrik.Hook.new("asker", ModelAsker)])
      %LLM.Turn{state: :waiting} = parked = run(asking, Context.new([Context.user("hi")]))
      [{call, _prompt}] = LLM.Turn.waiting(parked)

      assert %LLM.Turn{state: :done, messages: [answer]} =
               resume(governed(agent_id, [], []), parked, %{call.id => {:deny, "No."}})

      assert answer.role == :assistant
    end
  end
end
