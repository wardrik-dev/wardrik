defmodule WardrikCore.SubagentTest do
  use ExUnit.Case, async: true
  use Mimic

  import WardrikCore.Test.LLM

  alias WardrikCore.Context
  alias WardrikCore.Test.Echo
  alias WardrikCore.Test.ParkTools

  defmodule Seen do
    @behaviour WardrikCore.Middleware

    @impl true
    def call(%Context{step: :generate, metadata: %{test: pid}} = context, next, _opts) do
      send(pid, {:generate, context.subagent, Enum.map(context.tools, & &1.name)})
      next.(context)
    end

    def call(context, next, _opts), do: next.(context)
  end

  setup do
    stub(ReqLLM.StreamResponse, :process_stream, fn response, _opts -> {:ok, response} end)

    priced =
      struct(LLMDB.Model,
        provider: :anthropic,
        id: "claude-haiku-4-5",
        pricing: %{currency: "USD"}
      )

    stub(ReqLLM, :model, fn _spec -> {:ok, priced} end)

    :telemetry_test.attach_event_handlers(self(), [
      [:wardrik_core, :subagent, :started],
      [:wardrik_core, :subagent, :progress],
      [:wardrik_core, :subagent, :completed],
      [:wardrik_core, :subagent, :failed]
    ])

    context =
      Context.new(
        agent_id: "acme/scout",
        model: "anthropic:claude-haiku-4-5",
        capabilities: [Echo],
        middleware: [Seen],
        messages: [ReqLLM.Context.user("hi")],
        metadata: %{test: self()}
      )

    %{context: context}
  end

  defp stuck(test) do
    send(test, :stuck)

    receive do
      :never -> :ok
    end
  end

  defp used(response, input, output),
    do: %{response | usage: %{input_tokens: input, output_tokens: output, total_cost: 0.01}}

  test "answers in a turn of its own, and says what it measured", %{context: context} do
    responses = [
      used(calling([call("call_1", "echo", %{"text" => "x"})]), 10, 2),
      used(answer("Found it."), 20, 4)
    ]

    {:ok, queue} = Agent.start_link(fn -> responses end)

    stub(ReqLLM, :stream_text, fn _model, _messages, _opts ->
      {:ok, Agent.get_and_update(queue, fn [next | rest] -> {next, rest} end)}
    end)

    assert {:ok, %{text: "Found it.", labels: []}, measured} =
             WardrikCore.subagent(context, "Look", name: "researcher", instructions: "Research.")

    assert %{input_tokens: 30, output_tokens: 6} = measured
    assert_in_delta measured.usd, 0.02, 1.0e-9
    assert_received {:generate, "researcher", ["echo"]}

    assert_received {[:wardrik_core, :subagent, :started], _ref, _measurements,
                     %{
                       agent: %{name: "researcher"},
                       prompt: "Look",
                       agent_id: "acme/scout",
                       span: span
                     }}

    assert_received {[:wardrik_core, :subagent, :progress], _ref, _measurements,
                     %{
                       agent: %{name: "researcher"},
                       call: %{id: "call_1"},
                       tool_calls: 1,
                       span: ^span
                     }}

    assert_received {[:wardrik_core, :subagent, :completed], _ref, _measurements,
                     %{
                       message: %ReqLLM.Message{role: :assistant},
                       duration_ms: ms,
                       tool_calls: 1,
                       measurements: %{input_tokens: 30, output_tokens: 6},
                       span: ^span
                     }}

    assert is_integer(ms)
  end

  test "leaves out the tools it's told to", %{context: context} do
    stub(ReqLLM, :stream_text, fn _model, _messages, _opts -> {:ok, answer("Done.")} end)

    assert {:ok, %{text: "Done."}, _measured} =
             WardrikCore.subagent(context, "Look", except_tools: ["echo"])

    assert_received {:generate, "subagent", []}
  end

  test "fails once it runs out of time, with what it had measured", %{context: context} do
    test = self()
    calls = :counters.new(1, [])

    stub(ReqLLM, :stream_text, fn _model, _messages, _opts ->
      {:ok, used(calling([call("call_1", "echo", %{"text" => "x"})]), 10, 2)}
    end)

    stub(ReqLLM.StreamResponse, :process_stream, fn response, _opts ->
      :counters.add(calls, 1, 1)
      if :counters.get(calls, 1) > 1, do: stuck(test)
      {:ok, response}
    end)

    task = Task.async(fn -> WardrikCore.subagent(context, "Look", timeout: 200) end)
    assert_receive :stuck

    assert {:error, :timeout, %{input_tokens: 10, output_tokens: 2, usd: 0.01}} = Task.await(task)

    assert_received {[:wardrik_core, :subagent, :failed], _ref, _measurements,
                     %{error: :timeout, tool_calls: 1, measurements: %{input_tokens: 10}}}
  end

  test "fails where a call would wait on a person", %{context: context} do
    stub(ReqLLM, :stream_text, fn _model, _messages, _opts ->
      {:ok, used(calling([call("call_1", "echo", %{"text" => "x"})]), 10, 2)}
    end)

    context = %{context | middleware: [ParkTools]}

    assert {:error, "It came to a call that waits on a person, which a subagent can't wait on.",
            %{input_tokens: 10}} = WardrikCore.subagent(context, "Look")

    assert_received {[:wardrik_core, :subagent, :failed], _ref, _measurements, %{error: _error}}
  end
end
