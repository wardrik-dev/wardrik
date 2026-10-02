defmodule Wardrik.SubagentTest do
  use ExUnit.Case, async: true

  use Mimic

  alias Wardrik.Event
  alias Wardrik.LLM.Config
  alias Wardrik.Scope
  alias Wardrik.Subagent
  alias Wardrik.Test.EchoTool
  alias Wardrik.Test.LLMStub
  alias Wardrik.Test.SearchTool

  setup :verify_on_exit!

  setup do
    agent_id = Wardrik.Test.Fleet.key()
    :ok = Event.Bus.subscribe(agent_id)

    config = Config.new(tools: [EchoTool, SearchTool])

    {:ok, agent_id: agent_id, scope: Scope.root(config, agent_id, name: "turn")}
  end

  # Every turn reports what it was asked with, then answers `text`.
  defp stub_llm(text \\ "done") do
    test_pid = self()

    LLMStub.answering(fn asked ->
      send(test_pid, {:asked, asked})
      {:ok, LLMStub.final_answer(text)}
    end)
  end

  defp asked do
    assert_receive {:asked, asked}
    asked
  end

  test "returns the delegate's final answer", %{scope: scope} do
    stub_llm("competitors charge $20/mo")

    assert Subagent.run(scope, "pricing?") == {:ok, "competitors charge $20/mo"}
  end

  test "the prompt is the delegate's whole conversation", %{scope: scope} do
    stub_llm()

    {:ok, _text} = Subagent.run(scope, "pricing?")

    assert asked().prompt == "pricing?"
  end

  test "runs under its own child span", %{scope: scope} do
    stub_llm()

    {:ok, _text} = Subagent.run(scope, "pricing?")

    assert_receive %Event{payload: {:result, _text}} = event
    assert event.source.trace.parent_span_id == scope.source.trace.span_id
    refute Event.root?(event)
  end

  describe "content from outside" do
    test "a delegate that read some marks the process that ran it", %{scope: scope} do
      LLMStub.stream([
        LLMStub.tool_call("call_1", "fetch", %{"url" => "https://example.com"}),
        LLMStub.final_answer("It says to deploy.")
      ])

      scope = %{scope | config: Config.new(tools: [Wardrik.Test.Tools.Fetch])}

      assert {{:ok, "It says to deploy."}, true} =
               Subagent.watching(fn -> Subagent.run(scope, "Read it.") end)

      stub_llm()
      assert {{:ok, "done"}, false} = Subagent.watching(fn -> Subagent.run(scope, "Again.") end)
    end

    test "a delegate keeps what its tools declare, so a gated one waits on a person",
         %{scope: scope} do
      LLMStub.stream([LLMStub.tool_call("call_1", "deploy", %{"target" => "prod"})])
      scope = %{scope | config: Config.new(tools: [Wardrik.Test.Tools.Deploy, EchoTool])}

      assert Subagent.run(scope, "Ship it.", except_tools: ["echo"]) ==
               {:error, :approval_required}

      refute_received %Event{payload: {:tool_started, "call_1", _name, _args, _key}}
    end

    test "a delegate begins tainted under a tainted scope", %{scope: scope} do
      stub_llm()

      assert {{:ok, "done"}, true} =
               Subagent.watching(fn -> Subagent.run(%{scope | tainted: true}, "Go.") end)
    end

    test "a branch's mark reaches the process that fanned out", %{scope: scope} do
      stub_llm()

      assert {[{:a, {:ok, "done"}}, {:b, {:ok, "done"}}], true} =
               Subagent.watching(fn ->
                 Wardrik.Workflow.fan_out(%{scope | tainted: true}, [:a, :b], fn input, branch ->
                   Subagent.run(branch, "Look into #{input}.")
                 end)
               end)
    end
  end

  describe "events" do
    test "a named delegation announces itself on its own span", %{scope: scope} do
      stub_llm("about $20")

      {:ok, _text} = Subagent.run(scope, "pricing?", name: "pricing")

      assert_receive %Event{payload: {:span_started, "pricing"}} = opened
      assert_receive %Event{payload: {:delegation_started, "pricing?"}} = started
      assert_receive %Event{payload: {:delegation_finished, {:ok, "about $20"}, ms}} = finished
      assert_receive %Event{payload: {:span_finished, :ok, _ms}}

      assert started.source.trace.span_id == opened.source.trace.span_id
      assert finished.source.trace.span_id == opened.source.trace.span_id
      assert is_integer(ms) and ms >= 0
      assert Event.level(:delegation_started) == :lifecycle
    end

    test "repeated unnamed delegations have distinct identities", %{scope: scope} do
      stub_llm()

      {:ok, _text} = Subagent.run(scope, "pricing?")
      {:ok, _text} = Subagent.run(scope, "competitors?")

      assert_receive %Event{payload: {:delegation_started, "pricing?"}} = started
      assert_receive %Event{payload: {:delegation_started, "competitors?"}} = second
      assert started.source.trace.parent_span_id == scope.source.trace.span_id
      refute started.source.trace.span_id == second.source.trace.span_id
    end
  end

  defmodule AskHook do
    @behaviour Wardrik.Hook
    @impl true
    def init(_opts), do: nil
    @impl true
    def call(%Wardrik.Call{target: %Wardrik.Call.Tool{}}, _value), do: {:ask, "approval needed"}
    def call(_call, _value), do: :pass
  end

  test "a parked delegation reports an error that observers can fold", %{scope: scope} do
    LLMStub.stream([LLMStub.tool_call("blocked", "echo", %{"text" => "hello"})])

    assert Subagent.run(%{scope | hooks: [Wardrik.Hook.new("ask", AskHook)]}, "echo") ==
             {:error, :approval_required}

    assert_receive %Event{payload: {:delegation_started, "echo"}} = started

    assert_receive %Event{payload: {:delegation_finished, {:error, :approval_required}, _}} =
                     ended

    refute_receive %Event{payload: {:tool_started, "blocked", _, _, _}}

    delegations =
      Wardrik.Delegation.new()
      |> Wardrik.Delegation.fold(started)
      |> Wardrik.Delegation.fold(ended)

    assert [%{status: :error, error: :approval_required}] = Wardrik.Delegation.list(delegations)
  end

  describe "with a config of its own" do
    test "inherits the caller's model and tools by default", %{scope: scope} do
      stub_llm()

      {:ok, _text} = Subagent.run(scope, "pricing?")

      asked = asked()
      assert asked.tools == ["echo", "web_search"]
      assert asked.model == scope.config.model_spec
    end

    test "tools replaces the inherited set", %{scope: scope} do
      stub_llm()

      {:ok, _text} = Subagent.run(scope, "pricing?", tools: [EchoTool])

      assert asked().tools == ["echo"]
    end

    test "tools can be emptied, for work given everything it needs", %{scope: scope} do
      stub_llm()

      {:ok, _text} = Subagent.run(scope, "pricing?", tools: [])

      assert asked().tools == []
    end

    test "except_tools drops named tools from the inherited set", %{scope: scope} do
      stub_llm()

      {:ok, _text} = Subagent.run(scope, "pricing?", except_tools: ["echo"])

      assert asked().tools == ["web_search"]
    end

    test "a name that matches nothing drops nothing", %{scope: scope} do
      stub_llm()

      {:ok, _text} = Subagent.run(scope, "pricing?", except_tools: ["nope"])

      assert asked().tools == ["echo", "web_search"]
    end

    test "tools and except_tools compose: replaced, then narrowed", %{scope: scope} do
      stub_llm()

      {:ok, _text} =
        Subagent.run(scope, "pricing?", tools: [EchoTool, SearchTool], except_tools: ["echo"])

      assert asked().tools == ["web_search"]
    end

    test "system replaces the caller's persona", %{scope: scope} do
      stub_llm()
      caller = %{scope | config: %{scope.config | system: "You are Jon's assistant."}}

      {:ok, _text} = Subagent.run(caller, "pricing?", system: "You are a researcher.")

      assert asked().system == "You are a researcher."
    end

    test "the caller's persona is inherited when none is given", %{scope: scope} do
      stub_llm()
      caller = %{scope | config: %{scope.config | system: "You are Jon's assistant."}}

      {:ok, _text} = Subagent.run(caller, "pricing?")

      assert asked().system == "You are Jon's assistant."
    end

    test "model replaces the model and leaves the tools alone", %{scope: scope} do
      stub_llm()

      {:ok, _text} = Subagent.run(scope, "pricing?", model: {:test, model: "cheap"})

      asked = asked()
      assert asked.model == {:test, model: "cheap"}
      assert asked.tools == ["echo", "web_search"]
    end

    test "generation options can be set for the delegate alone", %{scope: scope} do
      stub_llm()

      {:ok, _text} =
        Subagent.run(scope, "pricing?", generation: [reasoning_token_budget: 500])

      assert scope.config.generation == []
    end

    test "config replaces the lot", %{scope: scope} do
      stub_llm()
      researcher = Config.new(model_spec: {:test, model: "m"}, tools: [SearchTool])

      {:ok, _text} = Subagent.run(scope, "pricing?", config: researcher)

      asked = asked()
      assert asked.tools == ["web_search"]
      assert asked.model == {:test, model: "m"}
    end

    test "the caller's own scope is left untouched", %{scope: scope} do
      stub_llm()

      {:ok, _text} = Subagent.run(scope, "pricing?", tools: [])

      assert scope.config |> Config.tools() |> Enum.map(& &1.name) == ["echo", "web_search"]
    end
  end

  describe "name" do
    test "puts the turn under a child span", %{scope: scope} do
      stub_llm()

      {:ok, _text} = Subagent.run(scope, "pricing?", name: "researcher")

      assert_receive %Event{payload: {:result, _text}} = event

      refute Event.root?(event)
      assert event.source.agent_id == scope.source.agent_id
      assert event.source.trace.trace_id == scope.source.trace.trace_id
      assert event.source.trace.parent_span_id == scope.source.trace.span_id
      assert event.source.trace.name == "researcher"
    end

    test "announces both ends of that span", %{scope: scope} do
      stub_llm()

      {:ok, _text} = Subagent.run(scope, "pricing?", name: "researcher")

      assert_receive %Event{payload: {:span_started, "researcher"}} = started
      assert_receive %Event{payload: {:span_finished, :ok, _ms}} = finished

      assert started.source.trace.span_id == finished.source.trace.span_id
    end

    test "a failed delegation closes its span as a failure", %{scope: scope} do
      stub(ReqLLM, :stream_text, fn _model, _context, _opts -> {:error, :rate_limited} end)

      ExUnit.CaptureLog.with_log(fn -> Subagent.run(scope, "pricing?", name: "researcher") end)

      assert_receive %Event{payload: {:span_finished, {:error, :rate_limited}, _ms}}
    end
  end

  test "an unnamed delegation inherits the scope's name on a distinct span", %{scope: scope} do
    stub_llm()

    {:ok, _text} = Subagent.run(scope, "pricing?")

    assert_receive %Event{payload: {:span_started, "turn"}} = event
    refute event.source.trace.span_id == scope.source.trace.span_id
  end

  test "a failed turn is reported to the caller", %{scope: scope} do
    stub(ReqLLM, :stream_text, fn _model, _context, _opts -> {:error, :rate_limited} end)

    {result, _log} = ExUnit.CaptureLog.with_log(fn -> Subagent.run(scope, "pricing?") end)

    assert result == {:error, :rate_limited}
  end

  test "a turn that produced no text answers empty rather than failing", %{scope: scope} do
    stub_llm("")

    assert Subagent.run(scope, "pricing?") == {:ok, ""}
  end
end
