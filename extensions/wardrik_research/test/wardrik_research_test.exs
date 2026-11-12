defmodule WardrikResearchTest do
  use ExUnit.Case, async: true
  use Mimic

  alias WardrikCore.Context
  alias WardrikResearch.Test.Echo
  alias WardrikResearch.Test.Seen

  setup do
    priced =
      struct(LLMDB.Model,
        provider: :anthropic,
        id: "claude-haiku-4-5",
        pricing: %{currency: "USD"}
      )

    stub(ReqLLM, :model, fn _spec -> {:ok, priced} end)
    stub(ReqLLM.StreamResponse, :process_stream, fn response, _opts -> {:ok, response} end)

    context =
      Context.new(
        agent_id: "acme/analyst",
        model: "anthropic:claude-haiku-4-5",
        capabilities: [Echo, WardrikResearch],
        middleware: [Seen],
        metadata: %{test: self()}
      )

    %{context: context}
  end

  defp answering(answer) do
    stub(ReqLLM, :stream_text, fn _model, messages, _opts ->
      {:ok, response(answer.(system(messages), prompt(messages)))}
    end)
  end

  defp response(message) do
    %ReqLLM.Response{
      id: "resp",
      model: "claude-haiku-4-5",
      context: nil,
      message: message,
      usage: %{input_tokens: 100, output_tokens: 10, total_cost: 0.001}
    }
  end

  defp system(messages), do: messages |> Enum.find(&(&1.role == :system)) |> text()
  defp prompt(messages), do: messages |> Enum.find(&(&1.role == :user)) |> text()

  defp text(%ReqLLM.Message{content: parts}), do: Enum.map_join(parts, "", & &1.text)

  defp research(context, args, opts \\ []) do
    [tool] = WardrikResearch.tools(context, opts)
    tool.run.(args, %{context | tools: [tool]})
  end

  test "researches each angle, then brings what they found into one report", %{context: context} do
    answering(fn system, prompt ->
      if system =~ "combine",
        do: ReqLLM.Context.assistant("The report, from: " <> prompt),
        else: ReqLLM.Context.assistant("Found on " <> List.last(String.split(prompt, ": ")))
    end)

    assert {:ok, %ReqLLM.ToolResult{output: output}, context} =
             research(context, %{topic: "WASM", angles: ["pricing", "players"]})

    assert %{"topic" => "WASM", "gaps" => [], "report" => report} = output
    assert report =~ "## pricing\n\nFound on pricing"
    assert report =~ "## players\n\nFound on players"
    assert %{input_tokens: 300, output_tokens: 30} = context.measurements

    assert_received {:offered, "researcher: pricing", ["echo"]}
    assert_received {:offered, "synthesis", []}
  end

  test "reports an angle that fails as a gap, and the rest still", %{context: context} do
    answering(fn system, prompt ->
      cond do
        system =~ "combine" ->
          ReqLLM.Context.assistant("The report.")

        prompt =~ "deep" ->
          ReqLLM.Context.assistant("",
            tool_calls: [ReqLLM.ToolCall.new("call_1", "echo", ~s({"text": "x"}))]
          )

        true ->
          ReqLLM.Context.assistant("Found it.")
      end
    end)

    assert {:ok, %ReqLLM.ToolResult{output: %{"gaps" => gaps}}, _context} =
             research(context, %{topic: "WASM", angles: ["deep", "shallow"]}, max_rounds: 1)

    assert gaps == [%{"angle" => "deep", "reason" => "it made as many model calls as it may"}]
  end

  test "reports an angle that runs out of time, and findings that can't be brought together", %{
    context: context
  } do
    stub(ReqLLM, :stream_text, fn _model, messages, _opts ->
      case {system(messages), prompt(messages)} do
        {"You combine" <> _rest, _prompt} -> {:error, :overloaded}
        {_system, "Topic: WASM\nYour angle: slow"} -> receive(do: (:never -> :ok))
        _researcher -> {:ok, response(ReqLLM.Context.assistant("Found it."))}
      end
    end)

    context = %{context | retries: [attempts: 0, on_exhausted: :fail]}

    assert {:error, "The findings couldn't be brought together: " <> _why, _context} =
             research(context, %{topic: "WASM", angles: ["slow", "quick"]}, timeout: 100)
  end

  test "fails only where every angle did", %{context: context} do
    answering(fn _system, _prompt ->
      ReqLLM.Context.assistant("",
        tool_calls: [ReqLLM.ToolCall.new("call_1", "echo", ~s({"text": "x"}))]
      )
    end)

    assert {:error, "Every angle failed. a: it made as many model calls as it may", context} =
             research(context, %{topic: "WASM", angles: ["a"]}, max_rounds: 1)

    assert %{input_tokens: 100} = context.measurements
  end

  test "takes the deployment's angles, each with what sets it apart", %{context: context} do
    test = self()

    answering(fn system, _prompt ->
      send(test, {:system, system})
      ReqLLM.Context.assistant("Found it.")
    end)

    angles = [%{angle: "pricing", prompt: "Think like a pricing analyst."}]
    assert {:ok, _result, _context} = research(context, %{topic: "WASM"}, angles: angles)
    assert_received {:system, "You're a researcher" <> _rest = researcher}
    assert researcher =~ "Think like a pricing analyst."

    assert_raise ArgumentError, "An angle takes :angle and :prompt, not :weight.", fn ->
      WardrikResearch.tools(context, angles: [%{angle: "x", weight: 2}])
    end

    assert_raise ArgumentError, ~s(An angle is %{angle: name, prompt: note}, not "x".), fn ->
      WardrikResearch.tools(context, angles: ["x"])
    end
  end
end
