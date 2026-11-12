defmodule WardrikCore.EventTest do
  use ExUnit.Case, async: false
  use Mimic

  import WardrikCore.Test.LLM

  alias WardrikCore.Context
  alias WardrikCore.Event
  alias WardrikCore.Turn

  defmodule Sink do
    @behaviour WardrikCore.Events

    @impl true
    def handle_event(%Event{} = event, test), do: send(test, {:event, event})
  end

  defmodule Refuses do
    @behaviour WardrikCore.Middleware

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
      opts[:on_chunk].(ReqLLM.StreamChunk.text("Hel"))
      opts[:on_chunk].(ReqLLM.StreamChunk.text("lo"))
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
end
