defmodule WardrikCore.EventTest do
  use ExUnit.Case, async: false
  use Mimic

  import WardrikCore.Test.LLM

  alias Wardrik.Context
  alias WardrikCore.Event
  alias WardrikCore.Turn

  defmodule Sink do
    @behaviour WardrikCore.Events

    @impl true
    def handle_event(%Event{} = event, test), do: send(test, {:event, event})
  end

  defmodule Refuses do
    @behaviour Wardrik.Middleware

    @impl true
    def call(%Context{step: {:tool_call, call}} = context, _next, _opts) do
      Event.emit(context, [:my_package, :refused], %{}, %{call: call.name})
      {:ok, %{context | response: {:error, "No."}}}
    end

    def call(context, next, _opts), do: next.(context)
  end

  setup :set_mimic_global

  setup do
    context =
      Context.new(
        agent_id: "events",
        model: "anthropic:claude-haiku-4-5",
        capabilities: [WardrikCore.Test.Echo],
        events: {Sink, self()},
        messages: [ReqLLM.Context.user("hi")]
      )

    %{context: context}
  end

  test "an agent's events reach its sink" do
    stub(ReqLLM.StreamResponse, :process_stream, fn response, _opts -> {:ok, response} end)
    expect(ReqLLM, :stream_text, fn _, _, _ -> {:ok, answer("done")} end)

    {:ok, agent} =
      WardrikCore.start_agent(
        agent_id: "events-#{System.unique_integer([:positive])}",
        model: "anthropic:claude-haiku-4-5",
        events: {Sink, self()}
      )

    :ok = WardrikCore.ask(agent, "hi")

    assert_receive {:event, %Event{name: [:wardrik_core, :message, :queued]}}
    assert_receive {:event, %Event{name: [:wardrik_core, :turn, :start]}}
    assert_receive {:event, %Event{name: [:wardrik_core, :step, :stop], metadata: %{step: :turn}}}

    assert_receive {:event,
                    %Event{name: [:wardrik_core, :turn, :stop], metadata: %{outcome: :ok}}}
  end

  test "text streams to the sink as it arrives", %{context: context} do
    stub(ReqLLM.StreamResponse, :process_stream, fn response, opts ->
      on_chunk = opts[:on_chunk]

      "Hel"
      |> ReqLLM.StreamChunk.text()
      |> on_chunk.()

      "lo"
      |> ReqLLM.StreamChunk.text()
      |> on_chunk.()

      {:ok, response}
    end)

    expect(ReqLLM, :stream_text, fn _, _, _ -> {:ok, answer("Hello")} end)

    assert {:ok, _context} = Turn.run(context)

    assert_receive {:event,
                    %Event{name: [:wardrik_core, :message, :delta], metadata: %{text: "Hel"}}}

    assert_receive {:event,
                    %Event{name: [:wardrik_core, :message, :delta], metadata: %{text: "lo"}}}
  end

  test "a package's events reach the same sink", %{context: context} do
    stub(ReqLLM.StreamResponse, :process_stream, fn response, _opts -> {:ok, response} end)

    ReqLLM
    |> expect(:stream_text, fn _, _, _ -> {:ok, calling([call("1", "echo", %{text: "a"})])} end)
    |> expect(:stream_text, fn _, _, _ -> {:ok, answer("done")} end)

    assert {:ok, _context} = Turn.run(%{context | middleware: [Refuses]})

    assert_receive {:event, %Event{name: [:my_package, :refused], metadata: %{call: "echo"}}}
  end

  test "emits to a sink given directly, and to telemetry alone without one" do
    assert :ok = Event.emit({Sink, self()}, [:my_vault, :stored], %{}, %{name: "github"})
    assert_receive {:event, %Event{name: [:my_vault, :stored], metadata: %{name: "github"}}}

    assert :ok = Event.emit(nil, [:my_vault, :stored], %{}, %{name: "github"})
    refute_received {:event, _}
  end

  describe "evaluations" do
    setup do
      expect(ReqLLM, :evaluate, fn _model, _state, _questions, _opts ->
        {:ok,
         %ReqLLM.Response{
           id: "eval",
           model: "jev",
           context: nil,
           message: nil,
           object: %{"send" => %{"probability" => 0.3}},
           usage: %{input_tokens: 40, output_tokens: 1, total_cost: 0.002}
         }}
      end)

      %{context: Context.new(agent_id: "a", events: {Sink, self()})}
    end

    test "each is a step of its own, with its answers and what it used", %{context: context} do
      args = [model: "typesafe:jev-latest", state: "x", questions: %{}]
      assert {:ok, answers, used} = WardrikCore.evaluate(context, args)
      assert used == %{input_tokens: 40, output_tokens: 1, usd: 0.002}

      assert_received {:event,
                       %Event{
                         name: [:wardrik_core, :step, :stop],
                         measurements: %{usd: 0.002, input_tokens: 40},
                         metadata: %{
                           step: {:evaluate, "typesafe:jev-latest"},
                           response: {:ok, ^answers}
                         }
                       }}
    end

    test "a step that judges leaves out what its evaluation reported", %{context: context} do
      judging = fn inner ->
        {:ok, _answers, used} =
          WardrikCore.evaluate(inner, model: "typesafe:jev-latest", state: "x", questions: %{})

        judged = Context.reported(inner, used)
        {:ok, Context.measure(judged, :usd, 0.5)}
      end

      assert {:ok, after_step} = Context.run(context, {:step, "judging"}, judging)

      assert_received {:event,
                       %Event{
                         name: [:wardrik_core, :step, :stop],
                         measurements: step,
                         metadata: %{step: {:step, "judging"}}
                       }}

      assert step.usd == 0.5
      refute Map.has_key?(step, :input_tokens)
      refute Map.has_key?(step, :reported_usd)

      # Budgets count what the context holds: the evaluation too.
      assert_in_delta after_step.measurements.usd, 0.502, 1.0e-9
    end
  end
end
