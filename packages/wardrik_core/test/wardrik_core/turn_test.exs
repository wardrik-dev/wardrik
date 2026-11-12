defmodule WardrikCore.TurnTest do
  use ExUnit.Case, async: true
  use Mimic

  import WardrikCore.Test.LLM

  alias WardrikCore.Context
  alias WardrikCore.Resume
  alias WardrikCore.Test.Echo
  alias WardrikCore.Test.ParkGenerate
  alias WardrikCore.Test.ParkTools
  alias WardrikCore.Turn

  defmodule Witness do
    @behaviour WardrikCore.Middleware

    @impl true
    def call(
          %Context{step: {:tool_call, _call}, resume: %Resume{} = resume} = context,
          next,
          _opts
        ) do
      send(context.metadata.test, {:resumed, resume})
      next.(context)
    end

    def call(context, next, _opts), do: next.(context)
  end

  defmodule Named do
    @behaviour WardrikCore.Capability

    @impl true
    def tools(_context, name) do
      [
        WardrikCore.Tool.new!(
          name: name,
          description: name,
          run: fn _args, _context -> {:ok, name} end
        )
      ]
    end
  end

  defmodule Lookup do
    @behaviour WardrikCore.Capability

    @impl true
    def tools(_context, _opts) do
      [
        WardrikCore.Tool.new!(
          name: "lookup",
          description: "Looks something up",
          annotations: [read_only: true],
          run: fn _args, _context -> {:ok, "found"} end
        )
      ]
    end
  end

  defmodule Stream do
    @behaviour WardrikCore.Middleware

    @impl true
    def call(%Context{step: :generate, metadata: %{test: pid}} = context, next, _opts) do
      handler = fn chunk -> send(pid, {:chunk, chunk}) end
      next.(%{context | on_chunk: [handler | context.on_chunk]})
    end

    def call(context, next, _opts), do: next.(context)
  end

  defmodule Report do
    @behaviour WardrikCore.Middleware

    @impl true
    def call(%Context{step: step, metadata: %{test: pid}} = context, next, _opts) do
      send(pid, {:step, step})
      next.(context)
    end
  end

  setup do
    stub(ReqLLM.StreamResponse, :process_stream, fn response, _opts -> {:ok, response} end)

    context =
      Context.new(
        model: "anthropic:claude-haiku-4-5",
        capabilities: [Echo],
        messages: [ReqLLM.Context.user("hi")],
        metadata: %{test: self()}
      )

    %{context: context}
  end

  test "a final answer ends the turn", %{context: context} do
    expect(ReqLLM, :stream_text, fn _model, _messages, _opts -> {:ok, answer("hello")} end)

    assert {:ok, %Context{messages: [_user, %{role: :assistant}]}} = Turn.run(context)
  end

  test "says what each model call used", %{context: context} do
    response = %{answer("hello") | usage: %{input_tokens: 10, output_tokens: 4, total_cost: 0.01}}
    expect(ReqLLM, :stream_text, fn _model, _messages, _opts -> {:ok, response} end)

    assert {:ok, %Context{measurements: %{input_tokens: 10, output_tokens: 4, usd: 0.01}}} =
             Turn.run(context)

    expect(ReqLLM, :stream_text, fn _model, _messages, _opts -> {:ok, response} end)

    assert {:ok, %Context{measurements: measurements}} =
             Turn.run(%{context | model: "zai_coding_plan:glm-5.3-flash"})

    assert %{input_tokens: 10, unpriced_calls: 1} = measurements
    refute Map.has_key?(measurements, :usd)
  end

  test "prices a model call at the agent's prices, over the catalog's", %{context: context} do
    usage = %{input_tokens: 1_000, cache_read_tokens: 400, output_tokens: 100, total_cost: 0.5}
    response = %{answer("hello") | usage: usage}
    prices = %{"zai_coding_plan:glm-5.3-flash" => [input: 1.0, output: 4.0, cache_read: 0.5]}
    expect(ReqLLM, :stream_text, 2, fn _model, _messages, _opts -> {:ok, response} end)

    assert {:ok, %Context{measurements: %{usd: usd}}} =
             Turn.run(%{context | model: "zai_coding_plan:glm-5.3-flash", prices: prices})

    assert_in_delta usd, (600 * 1.0 + 400 * 0.5 + 100 * 4.0) / 1_000_000, 1.0e-12

    assert {:ok, %Context{measurements: %{usd: 0.5}}} = Turn.run(%{context | prices: prices})
  end

  test "offers the capabilities' tools to the model", %{context: context} do
    expect(ReqLLM, :stream_text, fn _model, _messages, opts ->
      assert [%ReqLLM.Tool{name: "echo"}] = opts[:tools]
      {:ok, answer("hello")}
    end)

    assert {:ok, _} = Turn.run(context)
  end

  test "a {module, opts} capability gets its options", %{context: context} do
    expect(ReqLLM, :stream_text, fn _model, _messages, opts ->
      assert [%ReqLLM.Tool{name: "lookup"}] = opts[:tools]
      {:ok, answer("hello")}
    end)

    assert {:ok, _} = Turn.run(%{context | capabilities: [{Named, "lookup"}]})
  end

  test "runs tool calls and hands their results back to the model", %{context: context} do
    ReqLLM
    |> expect(:stream_text, fn _, _, _ -> {:ok, calling([call("1", "echo", %{text: "a"})])} end)
    |> expect(:stream_text, fn _, messages, _ ->
      assert %{role: :tool, tool_call_id: "1"} = List.last(messages)
      {:ok, answer("done")}
    end)

    assert {:ok, %Context{messages: messages}} = Turn.run(context)
    assert [:user, :assistant, :tool, :assistant] = Enum.map(messages, & &1.role)
  end

  defmodule Labelled do
    @behaviour WardrikCore.Capability

    @impl true
    def tools(_context, _opts) do
      [
        WardrikCore.Tool.new!(
          name: "search",
          description: "Searches the web",
          run: fn _args, _context -> {:ok, "a page"} end,
          annotations: [labels: ["outside"]]
        ),
        WardrikCore.Tool.new!(
          name: "read",
          description: "Reads a file",
          run: fn _args, _context ->
            {:ok, %ReqLLM.ToolResult{output: "a note", metadata: %{labels: ["books"]}}}
          end
        ),
        WardrikCore.Tool.new!(
          name: "fail",
          description: "Fails",
          run: fn _args, _context ->
            {:error, %ReqLLM.ToolResult{output: "a stranger's error", metadata: %{labels: ["x"]}}}
          end,
          annotations: [labels: ["outside"]]
        )
      ]
    end
  end

  test "a call's answer carries its tool's labels, and those it answers with, into the history",
       %{context: context} do
    calls = [call("1", "search"), call("2", "read"), call("3", "fail"), call("4", "echo")]

    ReqLLM
    |> expect(:stream_text, fn _, _, _ -> {:ok, calling(calls)} end)
    |> expect(:stream_text, fn _, _, _ -> {:ok, answer("done")} end)

    assert {:ok, %Context{messages: messages} = done} =
             Turn.run(%{context | capabilities: [Echo, Labelled]})

    labels = for %{role: :tool} = message <- messages, do: message.metadata[:labels]
    assert labels == [["outside"], ["books"], ["x", "outside"], nil]
    assert Context.labels(done) == ["books", "outside", "x"]
  end

  test "stops after max_rounds of tool use", %{context: context} do
    stub(ReqLLM, :stream_text, fn _, _, _ -> {:ok, calling([call("1", "echo")])} end)

    assert {:error, :max_rounds} = Turn.run(%{context | max_rounds: 2})
  end

  test "makes as many rounds of tool use as it needs with max_rounds of :infinity", %{
    context: context
  } do
    {:ok, rounds} = Agent.start_link(fn -> 30 end)

    stub(ReqLLM, :stream_text, fn _, _, _ ->
      case Agent.get_and_update(rounds, &{&1, &1 - 1}) do
        0 -> {:ok, answer("done")}
        _more -> {:ok, calling([call("1", "echo")])}
      end
    end)

    assert {:ok, %Context{}} = Turn.run(%{context | max_rounds: :infinity})
  end

  test "parks when a tool call parks", %{context: context} do
    expect(ReqLLM, :stream_text, fn _, _, _ -> {:ok, calling([call("1", "echo")])} end)

    assert {:park, {:tool_calls, [{%{id: "1"}, {:park, :needs_approval}}]}, %Context{}} =
             Turn.run(%{context | middleware: [ParkTools]})
  end

  test "middleware sees every step, outermost first", %{context: context} do
    ReqLLM
    |> expect(:stream_text, fn _, _, _ -> {:ok, calling([call("1", "echo", %{text: "a"})])} end)
    |> expect(:stream_text, fn _, _, _ -> {:ok, answer("done")} end)

    assert {:ok, %Context{step: nil}} = Turn.run(%{context | middleware: [Report]})

    assert_receive {:step, :turn}
    assert_receive {:step, :generate}
    assert_receive {:step, {:tool_call, %{id: "1"}}}
    assert_receive {:step, :generate}
  end

  test "a turn asked to yield ends before asking the model", %{context: context} do
    Turn.yield(self())

    assert {:ok, %Context{response: nil, messages: [%{role: :user}]}} = Turn.run(context)
  end

  test "middleware sees each streamed chunk once per model call", %{context: context} do
    stub(ReqLLM.StreamResponse, :process_stream, fn response, opts ->
      opts[:on_chunk].(ReqLLM.StreamChunk.text("hi"))
      {:ok, response}
    end)

    ReqLLM
    |> expect(:stream_text, fn _, _, _ -> {:ok, calling([call("1", "echo", %{text: "a"})])} end)
    |> expect(:stream_text, fn _, _, _ -> {:ok, answer("done")} end)

    assert {:ok, _} = Turn.run(%{context | middleware: [Stream]})

    assert_receive {:chunk, %ReqLLM.StreamChunk{type: :content, text: "hi"}}
    assert_receive {:chunk, %ReqLLM.StreamChunk{type: :content, text: "hi"}}
    refute_receive {:chunk, _}
  end

  test "a model error fails the turn", %{context: context} do
    expect(ReqLLM, :stream_text, fn _, _, _ -> {:error, :rate_limited} end)

    assert {:error, :rate_limited} = Turn.run(context)
  end

  describe "a model call that failed" do
    setup %{context: context} do
      {:ok, calls} = Agent.start_link(fn -> 0 end)
      %{context: %{context | retries: [max_wait: 0]}, calls: calls}
    end

    defp failing(calls, failures) do
      stub(ReqLLM, :stream_text, fn _model, _messages, _opts ->
        if Agent.get_and_update(calls, &{&1, &1 + 1}) < failures,
          do: {:error, %ReqLLM.Error.API.Stream{reason: "Stream failed: :timeout"}},
          else: {:ok, answer("hello")}
      end)
    end

    test "is tried again until it answers", %{context: context, calls: calls} do
      failing(calls, 2)
      assert {:ok, %Context{messages: [_user, %{role: :assistant}]}} = Turn.run(context)
      assert Agent.get(calls, & &1) == 3
    end

    test "waits on a person once its tries are spent, and tries afresh when they say so",
         %{context: context, calls: calls} do
      failing(calls, 3)
      context = %{context | retries: [attempts: 1, max_wait: 0]}

      assert {:park,
              %WardrikCore.Retry.Exhausted{interrupt: "model_approval", message: message} =
                exhausted, parked} =
               Turn.run(context)

      assert message =~ "The model failed 2 times: Stream failed: :timeout. Try again?"

      approved = %Resume{reason: exhausted, input: %{"model" => :approve}}
      assert {:ok, _context} = Turn.resume(parked, approved)

      denied = %{approved | input: %{"model" => {:deny, "Leave it."}}}
      assert {:error, "Leave it."} = Turn.resume(parked, denied)
    end

    test "fails the turn once its tries are spent where told to, or when it can't succeed",
         %{context: context, calls: calls} do
      failing(calls, 5)

      assert {:error, %ReqLLM.Error.API.Stream{}} =
               Turn.run(%{context | retries: [attempts: 1, max_wait: 0, on_exhausted: :fail]})

      stub(ReqLLM, :stream_text, fn _model, _messages, _opts ->
        {:error, %ReqLLM.Error.API.Request{reason: "bad", status: 400}}
      end)

      assert {:error, %ReqLLM.Error.API.Request{status: 400}} = Turn.run(context)
    end
  end

  describe "checkpoints" do
    test "a batch is checkpointed before its tools run", %{context: context} do
      test = self()

      checkpoint = fn checkpoint ->
        send(test, {:checkpoint, checkpoint})
        :ok
      end

      ReqLLM
      |> expect(:stream_text, fn _, _, _ -> {:ok, calling([call("1", "echo", %{text: "a"})])} end)
      |> expect(:stream_text, fn _, _, _ -> {:ok, answer("done")} end)

      assert {:ok, _} = Turn.run(%{context | checkpoint: checkpoint})

      assert_receive {:checkpoint,
                      %{calls: [%{id: "1"}], rounds: 25, messages: messages, metadata: %{test: _}}}

      assert [:user, :assistant] = Enum.map(messages, & &1.role)
    end

    test "recover/2 runs the checkpointed calls without asking the model again",
         %{context: context} do
      assistant = calling([call("1", "echo", %{text: "a"})]).message

      checkpoint = %{
        messages: context.messages ++ [assistant],
        calls: Enum.map(assistant.tool_calls, &WardrikCore.ToolCall.from_req_llm/1),
        rounds: 3,
        metadata: %{trace: "t1"},
        private: %{},
        span: WardrikCore.Span.root(),
        measurements: %{}
      }

      expect(ReqLLM, :stream_text, fn _, messages, _ ->
        assert %{role: :tool, tool_call_id: "1"} = List.last(messages)
        {:ok, answer("done")}
      end)

      assert {:ok, %Context{messages: messages, metadata: %{trace: "t1", test: _}}} =
               Turn.recover(context, checkpoint)

      assert [:user, :assistant, :tool, :assistant] = Enum.map(messages, & &1.role)
    end

    test "recover/2 parks a call it can't safely run again", %{context: context} do
      context = %{context | capabilities: [{Named, "refund"}]}

      assert {:park, {:tool_calls, [{%{id: "1"}, {:park, :in_doubt}}]}, _context} =
               Turn.recover(context, checkpoint(context, "refund"))
    end

    test "recover/2 runs a read-only call again", %{context: context} do
      context = %{context | capabilities: [Lookup]}

      expect(ReqLLM, :stream_text, fn _, messages, _ ->
        assert %{role: :tool, tool_call_id: "1"} = List.last(messages)
        {:ok, answer("done")}
      end)

      assert {:ok, _context} = Turn.recover(context, checkpoint(context, "lookup"))
    end

    test "a call in doubt runs again when a person approves", %{context: context} do
      context = %{context | capabilities: [{Named, "refund"}]}
      {:park, reason, parked} = Turn.recover(context, checkpoint(context, "refund"))

      expect(ReqLLM, :stream_text, fn _, messages, _ ->
        assert %{role: :tool, tool_call_id: "1"} = List.last(messages)
        {:ok, answer("done")}
      end)

      assert {:ok, _context} =
               Turn.resume(parked, %Resume{reason: reason, input: %{"1" => :approve}})
    end

    test "a call in doubt a person denies is answered with why", %{context: context} do
      context = %{context | capabilities: [{Named, "refund"}]}
      {:park, reason, parked} = Turn.recover(context, checkpoint(context, "refund"))

      expect(ReqLLM, :stream_text, fn _, messages, _ ->
        assert %{role: :tool, tool_call_id: "1", content: [%{text: text}]} = List.last(messages)
        assert text =~ "It may have run already."
        {:ok, answer("done")}
      end)

      denied = %{"1" => {:deny, "It may have run already."}}
      assert {:ok, _context} = Turn.resume(parked, %Resume{reason: reason, input: denied})
    end
  end

  describe "resume/2" do
    setup %{context: context} do
      context = %{context | middleware: [ParkTools]}

      expect(ReqLLM, :stream_text, fn _, _, _ ->
        {:ok, calling([call("1", "echo", %{text: "a"}), call("2", "echo", %{text: "b"})])}
      end)

      {:park, parked, context} = Turn.run(context)
      %{context: context, parked: parked}
    end

    test "approved calls run and the turn carries on", %{context: context, parked: parked} do
      expect(ReqLLM, :stream_text, fn _, messages, _ ->
        assert [%{role: :tool}, %{role: :tool}] = Enum.take(messages, -2)
        {:ok, answer("done")}
      end)

      assert {:ok, %Context{messages: messages}} =
               Turn.resume(context, %Resume{
                 reason: parked,
                 input: %{"1" => :approve, "2" => :approve}
               })

      assert [:user, :assistant, :tool, :tool, :assistant] = Enum.map(messages, & &1.role)
    end

    test "denied calls are answered with the reason", %{context: context, parked: parked} do
      expect(ReqLLM, :stream_text, fn _, messages, _ ->
        assert [%{tool_call_id: "1"}, %{tool_call_id: "2", content: [%{text: text}]}] =
                 Enum.take(messages, -2)

        assert text =~ "not today"
        {:ok, answer("done")}
      end)

      assert {:ok, _} =
               Turn.resume(context, %Resume{
                 reason: parked,
                 input: %{"1" => :approve, "2" => {:deny, "not today"}}
               })
    end

    test "undecided calls park the turn again", %{context: context, parked: parked} do
      assert {:park, parked, _context} =
               Turn.resume(context, %Resume{reason: parked, input: %{"1" => :approve}})

      assert {:tool_calls, [{%{id: "1"}, {:ok, "a"}}, {%{id: "2"}, {:park, _}}]} = parked
    end

    test "each parked call sees who resumed it", %{context: context, parked: parked} do
      context = %{context | middleware: [Witness | context.middleware]}
      expect(ReqLLM, :stream_text, fn _, _, _ -> {:ok, answer("done")} end)

      resume = %Resume{
        reason: parked,
        input: %{"1" => :approve, "2" => :approve},
        metadata: %{by: "maria"}
      }

      assert {:ok, _context} = Turn.resume(context, resume)

      assert_receive {:resumed, %Resume{reason: :needs_approval, metadata: %{by: "maria"}}}
      assert_receive {:resumed, %Resume{reason: :needs_approval, metadata: %{by: "maria"}}}
    end

    test "input that names no call leaves the turn parked", %{context: context, parked: parked} do
      assert {:park, ^parked, _context} =
               Turn.resume(context, %Resume{reason: parked, input: %{}})
    end
  end

  describe "resume/3 on a parked model call" do
    test "re-runs the model call, and the next one asks again", %{context: context} do
      context = %{context | middleware: [ParkGenerate]}
      assert {:park, :spend?, context} = Turn.run(context)

      expect(ReqLLM, :stream_text, fn _, _, _ ->
        {:ok, calling([call("1", "echo", %{text: "a"})])}
      end)

      assert {:park, :spend?, %Context{messages: messages}} =
               Turn.resume(context, %Resume{reason: :spend?, input: :ok})

      assert [:user, :assistant, :tool] = Enum.map(messages, & &1.role)
    end
  end

  defp checkpoint(context, name) do
    assistant = calling([call("1", name)]).message

    %{
      messages: context.messages ++ [assistant],
      calls: Enum.map(assistant.tool_calls, &WardrikCore.ToolCall.from_req_llm/1),
      rounds: 3,
      metadata: %{},
      private: %{},
      span: WardrikCore.Span.root(),
      measurements: %{}
    }
  end
end
