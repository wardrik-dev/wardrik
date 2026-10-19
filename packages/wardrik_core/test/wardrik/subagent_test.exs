defmodule Wardrik.SubagentTest do
  use ExUnit.Case, async: true

  alias Wardrik.Event
  alias Wardrik.Host
  alias Wardrik.LLM.Config
  alias Wardrik.LLM.Error
  alias Wardrik.Run
  alias Wardrik.Subagent
  alias Wardrik.Test.EchoTool
  alias Wardrik.Test.LLM
  alias Wardrik.Test.SearchTool

  @rate_limited %Error{status: 429, message: "rate limited"}

  setup do
    agent_id = Wardrik.Test.Fleet.id()
    :ok = Event.Bus.subscribe(agent_id)

    config = Config.new(tools: [EchoTool, SearchTool])

    host = Wardrik.Test.host(llm: LLM.start())
    {:ok, agent_id: agent_id, run: Run.root(config, agent_id, name: "turn", host: host)}
  end

  # Every turn under `run` reports what it was asked with, then answers `text`.
  defp stub_llm(run, text \\ "done") do
    test_pid = self()

    LLM.answering(Host.llm(run.host), fn asked ->
      send(test_pid, {:asked, asked})
      LLM.final_answer(text)
    end)
  end

  defp stream(run, answers), do: LLM.stream(Host.llm(run.host), answers)

  defp asked do
    assert_receive {:asked, asked}
    asked
  end

  test "returns the delegate's final answer", %{run: run} do
    stub_llm(run, "competitors charge $20/mo")

    assert Subagent.run(run, "pricing?") == {:ok, "competitors charge $20/mo"}
  end

  test "the prompt is the delegate's whole conversation", %{run: run} do
    stub_llm(run)

    {:ok, _text} = Subagent.run(run, "pricing?")

    assert asked().prompt == "pricing?"
  end

  test "runs under its own child span", %{run: run} do
    stub_llm(run)

    {:ok, _text} = Subagent.run(run, "pricing?")

    assert_receive %Event{payload: %Event.Result{}} = event
    assert event.source.trace.parent_span_id == run.source.trace.span_id
    refute Event.root?(event)
  end

  describe "what a delegate read" do
    test "a delegate that read content marks the process that ran it with its labels",
         %{run: run} do
      stream(run, [
        LLM.tool_call("call_1", "fetch", %{"url" => "https://example.com"}),
        LLM.final_answer("It says to deploy.")
      ])

      run = %{run | config: Config.new(tools: [Wardrik.Test.Tools.Fetch])}

      assert {{:ok, "It says to deploy."}, ["outside"]} =
               Subagent.watching(fn -> Subagent.run(run, "Read it.") end)

      stub_llm(run)
      assert {{:ok, "done"}, []} = Subagent.watching(fn -> Subagent.run(run, "Again.") end)
    end

    test "a delegate keeps what its tools declare, so a gated one waits on a person",
         %{run: run} do
      stream(run, [LLM.tool_call("call_1", "deploy", %{"target" => "prod"})])
      run = %{run | config: Config.new(tools: [Wardrik.Test.Tools.Deploy, EchoTool])}

      assert Subagent.run(run, "Ship it.", except_tools: ["echo"]) ==
               {:error, :approval_required}

      refute_received %Event{payload: %Event.ToolStarted{call_id: "call_1"}}
    end

    test "a delegate begins with the labels of its run", %{run: run} do
      stub_llm(run)

      assert {{:ok, "done"}, ["books"]} =
               Subagent.watching(fn -> Subagent.run(%{run | labels: ["books"]}, "Go.") end)
    end

    test "read/1 marks this process with labels a delegate read in another", %{run: run} do
      stub_llm(run)

      {{:ok, "done"}, labels} =
        Task.await(
          Task.async(fn ->
            Subagent.watching(fn -> Subagent.run(%{run | labels: ["outside"]}, "Go.") end)
          end)
        )

      assert {:ok, ["outside"]} = Subagent.watching(fn -> Subagent.read(labels) end)
    end
  end

  describe "events" do
    test "a named delegation announces itself on its own span", %{run: run} do
      stub_llm(run, "about $20")

      {:ok, _text} = Subagent.run(run, "pricing?", name: "pricing")

      assert_receive %Event{payload: %Event.SpanStarted{name: "pricing"}} = opened
      assert_receive %Event{payload: %Event.DelegationStarted{prompt: "pricing?"}} = started

      assert_receive %Event{
                       payload: %Event.DelegationFinished{
                         outcome: {:ok, "about $20"},
                         duration_ms: ms
                       }
                     } = finished

      assert_receive %Event{payload: %Event.SpanFinished{outcome: :ok}}

      assert started.source.trace.span_id == opened.source.trace.span_id
      assert finished.source.trace.span_id == opened.source.trace.span_id
      assert is_integer(ms) and ms >= 0
      assert Event.level(:delegation_started) == :lifecycle
    end

    test "repeated unnamed delegations have distinct identities", %{run: run} do
      stub_llm(run)

      {:ok, _text} = Subagent.run(run, "pricing?")
      {:ok, _text} = Subagent.run(run, "competitors?")

      assert_receive %Event{payload: %Event.DelegationStarted{prompt: "pricing?"}} = started
      assert_receive %Event{payload: %Event.DelegationStarted{prompt: "competitors?"}} = second
      assert started.source.trace.parent_span_id == run.source.trace.span_id
      refute started.source.trace.span_id == second.source.trace.span_id
    end
  end

  defmodule AskHook do
    use Wardrik.Hook
    @impl true
    def init(_opts), do: nil
    @impl true
    def call(%Wardrik.Call{target: %Wardrik.Call.Tool{}}, _value), do: {:ask, "approval needed"}
    def call(_call, _value), do: :pass
  end

  test "a parked delegation reports an error that observers can fold", %{run: run} do
    stream(run, [LLM.tool_call("blocked", "echo", %{"text" => "hello"})])

    assert Subagent.run(%{run | hooks: [Wardrik.Hook.new("ask", AskHook)]}, "echo") ==
             {:error, :approval_required}

    assert_receive %Event{payload: %Event.DelegationStarted{prompt: "echo"}} = started

    assert_receive %Event{
                     payload: %Event.DelegationFinished{outcome: {:error, :approval_required}}
                   } =
                     ended

    refute_receive %Event{payload: %Event.ToolStarted{call_id: "blocked"}}

    delegations =
      Wardrik.Delegation.new()
      |> Wardrik.Delegation.fold(started)
      |> Wardrik.Delegation.fold(ended)

    assert [%{status: :error, error: :approval_required}] = Wardrik.Delegation.list(delegations)
  end

  describe "with a config of its own" do
    test "inherits the caller's model and tools by default", %{run: run} do
      stub_llm(run)

      {:ok, _text} = Subagent.run(run, "pricing?")

      asked = asked()
      assert asked.tools == ["echo", "web_search"]
      assert asked.model == run.config.model_spec
    end

    test "tools replaces the inherited set", %{run: run} do
      stub_llm(run)

      {:ok, _text} = Subagent.run(run, "pricing?", tools: [EchoTool])

      assert asked().tools == ["echo"]
    end

    test "tools can be emptied, for work given everything it needs", %{run: run} do
      stub_llm(run)

      {:ok, _text} = Subagent.run(run, "pricing?", tools: [])

      assert asked().tools == []
    end

    test "except_tools drops named tools from the inherited set", %{run: run} do
      stub_llm(run)

      {:ok, _text} = Subagent.run(run, "pricing?", except_tools: ["echo"])

      assert asked().tools == ["web_search"]
    end

    test "a name that matches nothing drops nothing", %{run: run} do
      stub_llm(run)

      {:ok, _text} = Subagent.run(run, "pricing?", except_tools: ["nope"])

      assert asked().tools == ["echo", "web_search"]
    end

    test "tools and except_tools compose: replaced, then narrowed", %{run: run} do
      stub_llm(run)

      {:ok, _text} =
        Subagent.run(run, "pricing?", tools: [EchoTool, SearchTool], except_tools: ["echo"])

      assert asked().tools == ["web_search"]
    end

    test "system replaces the caller's persona", %{run: run} do
      stub_llm(run)
      caller = %{run | config: %{run.config | system: "You are Jon's assistant."}}

      {:ok, _text} = Subagent.run(caller, "pricing?", system: "You are a researcher.")

      assert asked().system == "You are a researcher."
    end

    test "the caller's persona is inherited when none is given", %{run: run} do
      stub_llm(run)
      caller = %{run | config: %{run.config | system: "You are Jon's assistant."}}

      {:ok, _text} = Subagent.run(caller, "pricing?")

      assert asked().system == "You are Jon's assistant."
    end

    test "model replaces the model and leaves the tools alone", %{run: run} do
      stub_llm(run)

      {:ok, _text} = Subagent.run(run, "pricing?", model: {:test, model: "cheap"})

      asked = asked()
      assert asked.model == {:test, model: "cheap"}
      assert asked.tools == ["echo", "web_search"]
    end

    test "generation options can be set for the delegate alone", %{run: run} do
      stub_llm(run)

      {:ok, _text} =
        Subagent.run(run, "pricing?", generation: [reasoning_token_budget: 500])

      assert run.config.generation == []
    end

    test "config replaces the lot", %{run: run} do
      stub_llm(run)
      researcher = Config.new(model_spec: {:test, model: "m"}, tools: [SearchTool])

      {:ok, _text} = Subagent.run(run, "pricing?", config: researcher)

      asked = asked()
      assert asked.tools == ["web_search"]
      assert asked.model == {:test, model: "m"}
    end

    test "the caller's own run is left untouched", %{run: run} do
      stub_llm(run)

      {:ok, _text} = Subagent.run(run, "pricing?", tools: [])

      assert run.config |> Config.tools() |> Enum.map(& &1.name) == ["echo", "web_search"]
    end
  end

  describe "name" do
    test "puts the turn under a child span", %{run: run} do
      stub_llm(run)

      {:ok, _text} = Subagent.run(run, "pricing?", name: "researcher")

      assert_receive %Event{payload: %Event.Result{}} = event

      refute Event.root?(event)
      assert event.source.agent_id == run.source.agent_id
      assert event.source.trace.trace_id == run.source.trace.trace_id
      assert event.source.trace.parent_span_id == run.source.trace.span_id
      assert event.source.trace.name == "researcher"
    end

    test "announces both ends of that span", %{run: run} do
      stub_llm(run)

      {:ok, _text} = Subagent.run(run, "pricing?", name: "researcher")

      assert_receive %Event{payload: %Event.SpanStarted{name: "researcher"}} = started
      assert_receive %Event{payload: %Event.SpanFinished{outcome: :ok}} = finished

      assert started.source.trace.span_id == finished.source.trace.span_id
    end

    test "a failed delegation closes its span as a failure", %{run: run} do
      stream(run, [@rate_limited])

      ExUnit.CaptureLog.with_log(fn ->
        Subagent.run(failing(run), "pricing?", name: "researcher")
      end)

      assert_receive %Event{payload: %Event.SpanFinished{outcome: {:error, @rate_limited}}}
    end
  end

  test "an unnamed delegation inherits the run's name on a distinct span", %{run: run} do
    stub_llm(run)

    {:ok, _text} = Subagent.run(run, "pricing?")

    assert_receive %Event{payload: %Event.SpanStarted{name: "turn"}} = event
    refute event.source.trace.span_id == run.source.trace.span_id
  end

  test "a failed turn is reported to the caller", %{run: run} do
    stream(run, [@rate_limited])

    {result, _log} = ExUnit.CaptureLog.with_log(fn -> Subagent.run(failing(run), "pricing?") end)

    assert result == {:error, @rate_limited}
  end

  # A run whose failed model call fails the turn at once.
  defp failing(run),
    do: %{run | retry: %Wardrik.LLM.Retry.Backoff{attempts: 0, on_exhausted: :fail}}

  test "a turn that produced no text answers empty rather than failing", %{run: run} do
    stub_llm(run, "")

    assert Subagent.run(run, "pricing?") == {:ok, ""}
  end
end
