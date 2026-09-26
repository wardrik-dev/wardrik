defmodule WardrikResearch.DeepTest do
  use ExUnit.Case, async: true

  use Mimic

  alias Wardrik.Event
  alias Wardrik.LLM.Config
  alias Wardrik.Scope
  alias Wardrik.Test.Calls
  alias Wardrik.Test.LLMStub
  alias Wardrik.Test.SearchTool
  alias Wardrik.Workflow
  alias WardrikResearch.Deep

  setup :verify_on_exit!

  setup do
    agent_id = Wardrik.Test.Fleet.key()
    :ok = Event.Bus.subscribe(agent_id)

    config = Config.new(tools: [SearchTool, Deep])

    {:ok, agent_id: agent_id, scope: Scope.root(config, agent_id, name: "turn")}
  end

  # Every turn reports itself, then answers according to what it was asked.
  # `crash_on` names angles whose researcher dies.
  defp stub_llm(crash_on \\ []) do
    test_pid = self()

    LLMStub.answering(fn asked ->
      kind = if asked.prompt =~ "Your angle:", do: :research, else: :synthesis
      send(test_pid, {:turn, kind, asked})

      cond do
        kind == :synthesis -> {:ok, LLMStub.final_answer("the combined report")}
        Enum.any?(crash_on, &(asked.prompt =~ &1)) -> exit(:no_signal)
        true -> {:ok, LLMStub.final_answer("what I found")}
      end
    end)
  end

  defp turns do
    receive do
      {:turn, kind, asked} -> [{kind, asked} | turns()]
    after
      0 -> []
    end
  end

  defp research_turns, do: for({:research, asked} <- turns(), do: asked)

  defp synthesis_turn do
    assert [asked] = for({:synthesis, asked} <- turns(), do: asked)
    asked
  end

  defp quietly(fun), do: fun |> ExUnit.CaptureLog.with_log() |> elem(0)

  describe "run/3" do
    test "researches every angle and returns the synthesised report", %{scope: scope} do
      stub_llm()

      assert {:ok, result} = Deep.run(%{topic: "widget pricing"}, scope, [])

      assert result["topic"] == "widget pricing"
      assert result["report"] == "the combined report"
      assert result["gaps"] == []
    end

    test "one researcher per angle", %{scope: scope} do
      stub_llm()

      {:ok, _result} = Deep.run(%{topic: "widgets"}, scope, [])

      assert Enum.count(research_turns()) == 5
    end

    test "researchers get the agent's tools, minus this workflow", %{scope: scope} do
      stub_llm()

      assert scope.config |> Config.tools() |> Enum.map(& &1.name) |> Enum.sort() == [
               "deep_research",
               "web_search"
             ]

      {:ok, _result} = Deep.run(%{topic: "widgets"}, scope, [])

      for asked <- research_turns(), do: assert(asked.tools == ["web_search"])
    end

    test "the synthesiser gets no tools at all", %{scope: scope} do
      stub_llm()

      {:ok, _result} = Deep.run(%{topic: "widgets"}, scope, [])

      assert synthesis_turn().tools == []
    end

    test "each researcher is told the topic and its own angle", %{scope: scope} do
      stub_llm()

      {:ok, _result} = Deep.run(%{topic: "widgets", angles: ["pricing", "rivals"]}, scope, [])

      prompts = Enum.map(research_turns(), & &1.prompt)

      assert Enum.any?(prompts, &(&1 =~ "Your angle: pricing"))
      assert Enum.any?(prompts, &(&1 =~ "Your angle: rivals"))
      assert Enum.all?(prompts, &(&1 =~ "Topic: widgets"))
    end

    test "the synthesiser is given every finding under its angle", %{scope: scope} do
      stub_llm()

      {:ok, _result} = Deep.run(%{topic: "widgets", angles: ["pricing"]}, scope, [])

      prompt = synthesis_turn().prompt

      assert prompt =~ "Topic: widgets"
      assert prompt =~ "## pricing"
      assert prompt =~ "what I found"
    end
  end

  describe "personas" do
    test "a researcher is told how to research, not just what", %{scope: scope} do
      stub_llm()

      {:ok, _result} = Deep.run(%{topic: "widgets", angles: ["pricing"]}, scope, [])

      assert [%{system: system}] = research_turns()

      assert system =~ "one angle of a larger question"
      assert system =~ "rather than answering from memory"
    end

    test "the synthesiser gets a persona of its own", %{scope: scope} do
      stub_llm()

      {:ok, _result} = Deep.run(%{topic: "widgets", angles: ["pricing"]}, scope, [])

      assert synthesis_turn().system =~ "combine several researchers' reports"
    end

    test "a persona is prepended, never left in the conversation", %{scope: scope} do
      stub_llm()

      {:ok, _result} = Deep.run(%{topic: "widgets", angles: ["pricing"]}, scope, [])

      assert [%{prompt: prompt}] = research_turns()

      refute prompt =~ "rather than answering from memory"
    end

    test "an angle's prompt is added to the shared persona, not swapped for it", %{scope: scope} do
      stub_llm()

      angles = [%{angle: "plain"}, %{angle: "special", prompt: "Think like a pricing analyst."}]
      {:ok, _result} = Deep.run(%{topic: "widgets"}, scope, angles: angles)

      personas = Map.new(research_turns(), &{&1.prompt =~ "special", &1.system})

      assert String.starts_with?(personas[true], personas[false])
      assert personas[true] =~ "Think like a pricing analyst."
      refute personas[false] =~ "Think like a pricing analyst."
    end

    test "each angle gets only its own prompt", %{scope: scope} do
      stub_llm()

      angles = [
        %{angle: "pricing", prompt: "Think like a pricing analyst."},
        %{angle: "security", prompt: "Prefer primary advisories."}
      ]

      {:ok, _result} = Deep.run(%{topic: "widgets"}, scope, angles: angles)

      for asked <- research_turns() do
        if asked.prompt =~ "Your angle: pricing" do
          assert asked.system =~ "pricing analyst"
          refute asked.system =~ "primary advisories"
        else
          assert asked.system =~ "primary advisories"
          refute asked.system =~ "pricing analyst"
        end
      end
    end
  end

  describe "angles" do
    test "the caller can choose them, and the width follows", %{scope: scope} do
      stub_llm()

      {:ok, _result} = Deep.run(%{topic: "widgets", angles: ["one", "two", "three"]}, scope, [])

      assert Enum.count(research_turns()) == 3
    end

    test "an empty list falls back to the configured ones", %{scope: scope} do
      stub_llm()

      {:ok, _result} = Deep.run(%{topic: "widgets", angles: []}, scope, [])

      assert Enum.count(research_turns()) == 5
    end

    test "a caller's angles override the deployment's", %{scope: scope} do
      stub_llm()

      angles = [%{angle: "pricing", prompt: "Think like a pricing analyst."}]
      {:ok, _result} = Deep.run(%{topic: "widgets", angles: ["rivals"]}, scope, angles: angles)

      assert [asked] = research_turns()

      assert asked.prompt =~ "Your angle: rivals"
      refute asked.system =~ "pricing analyst"
    end

    test "an unknown key is a configuration error, not a lost persona", %{scope: scope} do
      assert_raise ArgumentError, ~r/unknown angle keys \[:promt\]/, fn ->
        Deep.run(%{topic: "widgets"}, scope, angles: [%{angle: "pricing", promt: "typo"}])
      end
    end

    test "anything that is not an angle map raises", %{scope: scope} do
      assert_raise ArgumentError, ~r/expected an angle as/, fn ->
        Deep.run(%{topic: "widgets"}, scope, angles: ["a bare string"])
      end
    end

    test "a malformed angle is heard where the tool is built" do
      assert_raise ArgumentError, ~r/expected an angle as/, fn ->
        Config.new(tools: [Deep.tool(angles: [{"pricing", "nope"}])])
      end
    end
  end

  describe "gaps" do
    test "a dead angle is reported as a gap and the rest are still synthesised", %{scope: scope} do
      stub_llm(["rivals"])

      assert {:ok, result} =
               quietly(fn ->
                 Deep.run(%{topic: "widgets", angles: ["pricing", "rivals"]}, scope, [])
               end)

      assert result["report"] == "the combined report"
      assert [%{"angle" => "rivals", "reason" => reason}] = result["gaps"]
      assert reason =~ "no_signal"
    end

    test "a gap's findings are kept out of the synthesis prompt", %{scope: scope} do
      stub_llm(["rivals"])

      quietly(fn -> Deep.run(%{topic: "widgets", angles: ["pricing", "rivals"]}, scope, []) end)

      prompt = synthesis_turn().prompt

      assert prompt =~ "## pricing"
      refute prompt =~ "## rivals"
    end

    test "an angle that runs over its time is a gap, and the rest are still synthesised", %{
      scope: scope
    } do
      LLMStub.answering(fn asked ->
        # The rivals researcher never answers; the fan-out has to give up on it.
        if asked.prompt =~ "rivals", do: receive(do: (:never -> :ok))

        if asked.prompt =~ "Your angle:",
          do: {:ok, LLMStub.final_answer("what I found")},
          else: {:ok, LLMStub.final_answer("the combined report")}
      end)

      assert {:ok, result} =
               quietly(fn ->
                 Deep.run(%{topic: "widgets", angles: ["pricing", "rivals"]}, scope, timeout: 100)
               end)

      assert result["report"] == "the combined report"
      assert [%{"angle" => "rivals", "reason" => ":timeout"}] = result["gaps"]
    end

    test "a researcher that keeps asking for tools is stopped at its iteration cap", %{
      scope: scope
    } do
      test_pid = self()

      LLMStub.answering(fn asked ->
        cond do
          asked.prompt =~ "Your angle:" and asked.tools == [] ->
            send(test_pid, {:turn, :research, asked})
            {:ok, LLMStub.final_answer("what I found before the cap")}

          asked.prompt =~ "Your angle:" ->
            send(test_pid, {:turn, :research, asked})
            id = "call_#{System.unique_integer([:positive])}"
            {:ok, LLMStub.tool_call(id, "web_search", %{query: "one more"})}

          true ->
            send(test_pid, {:turn, :synthesis, asked})
            {:ok, LLMStub.final_answer("the combined report")}
        end
      end)

      assert {:ok, result} =
               quietly(fn ->
                 Deep.run(%{topic: "widgets", angles: ["pricing"]}, scope, max_iterations: 3)
               end)

      # Three rounds of searching, then one closing call without tools.
      all = turns()
      assert [_first, _second, _third, closing] = for({:research, asked} <- all, do: asked)
      assert closing.tools == []
      assert [synthesis] = for({:synthesis, asked} <- all, do: asked)
      assert synthesis.prompt =~ "what I found before the cap"
      assert result["report"] == "the combined report"
    end

    test "losing every angle is an error, because there is nothing to synthesise", %{scope: scope} do
      stub_llm(["pricing", "rivals"])

      assert {:error, {:no_findings, gaps}} =
               quietly(fn ->
                 Deep.run(%{topic: "widgets", angles: ["pricing", "rivals"]}, scope, [])
               end)

      assert [%{"angle" => "pricing"}, %{"angle" => "rivals"}] = gaps
    end
  end

  describe "spans" do
    test "each angle has a distinct delegation span under its branch", %{scope: scope} do
      stub_llm()

      {:ok, _result} = Deep.run(%{topic: "widgets", angles: ["pricing", "rivals"]}, scope, [])

      spans = collect_spans()

      assert Enum.sort(Enum.map(spans, & &1.name)) == ["pricing", "rivals", "synthesis"]

      for span <- spans do
        assert span.trace_id == scope.source.trace.trace_id

        if span.name == "synthesis" do
          assert span.parent_span_id == scope.source.trace.span_id
        else
          refute span.parent_span_id == scope.source.trace.span_id
        end
      end

      assert MapSet.size(MapSet.new(spans, & &1.span_id)) == 3
    end

    test "every event stays on the calling agent's topic", %{scope: scope, agent_id: agent_id} do
      stub_llm()

      {:ok, _result} = Deep.run(%{topic: "widgets", angles: ["pricing"]}, scope, [])

      assert_receive %Event{payload: {:result, _text}} = event
      assert event.source.agent_id == agent_id
    end
  end

  describe "as a tool" do
    test "declares the deep_research tool" do
      tool = Deep.tool()

      assert tool.name == "deep_research"
      assert {Wardrik.Tool, :invoke, [{Workflow, :call, [{Deep, _opts}]}]} = tool.callback
      assert Keyword.fetch!(tool.parameter_schema, :topic)[:required]
      refute Keyword.fetch!(tool.parameter_schema, :angles)[:required]
    end

    test "a config naming the module resolves it like any other tool" do
      config = Config.new(tools: [Deep])

      assert config.tools == [Deep]
      assert Enum.map(Config.tools(config), & &1.name) == ["deep_research"]
    end

    test "tool/1 carries its angles into the sweep", %{scope: scope} do
      stub_llm()
      tool = Deep.tool(angles: [%{angle: "pricing", prompt: "Think like a pricing analyst."}])

      assert {:ok, %{"ok" => true}} = Calls.run(tool, %{"topic" => "widgets"}, scope)

      assert [asked] = research_turns()
      assert asked.system =~ "pricing analyst"
    end

    test "runs from a tool call, wrapped as a tool result", %{scope: scope} do
      stub_llm()

      assert {:ok, %{"ok" => true, "result" => result}} =
               Deep
               |> Workflow.call(
                 Calls.tool(
                   "deep_research",
                   %{topic: "widgets", angles: ["pricing"]},
                   scope
                 )
               )
               |> Calls.result()

      assert result["report"] == "the combined report"
    end

    test "a sweep that found nothing answers the model rather than failing the turn", %{
      scope: scope
    } do
      stub_llm(["pricing"])

      assert {:ok, %{"ok" => false, "error" => %{"code" => "no_findings"}}} =
               quietly(fn ->
                 Deep
                 |> Workflow.call(
                   Calls.tool(
                     "deep_research",
                     %{topic: "widgets", angles: ["pricing"]},
                     scope
                   )
                 )
                 |> Calls.result()
               end)
    end
  end

  defp collect_spans(acc \\ []) do
    receive do
      %Event{payload: {:result, _text}, source: source} -> collect_spans([source.trace | acc])
      %Event{} -> collect_spans(acc)
    after
      0 -> acc
    end
  end
end
