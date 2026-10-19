defmodule Wardrik.RunTest do
  use ExUnit.Case, async: true

  alias Wardrik.AgentID
  alias Wardrik.Event
  alias Wardrik.LLM.Config
  alias Wardrik.Run
  alias Wardrik.Test.EchoTool
  alias Wardrik.Trace

  import Wardrik.AgentID, only: [sigil_A: 2]

  defp subscribed do
    agent_id = Wardrik.Test.Fleet.id()
    :ok = Event.Bus.subscribe(agent_id)
    Run.root(Config.new(), agent_id, name: "turn")
  end

  test "root/3 pairs a config with a fresh root span" do
    config = Config.new()
    run = Run.root(config, ~A"acme/assistant", name: "turn")

    assert run.config == config
    assert run.source.agent_id == ~A"acme/assistant"
    assert Trace.root?(run.source.trace)
    assert run.source.trace.name == "turn"
  end

  test "child/2 keeps the config and topic, and descends a span" do
    run = Run.root(Config.new(), ~A"acme/assistant")
    child = Run.child(run, name: "echo")

    assert child.config == run.config
    assert child.source.agent_id == ~A"acme/assistant"
    assert child.source.trace.parent_span_id == run.source.trace.span_id
    assert child.source.trace.name == "echo"
  end

  test "child/2 carries the config, tools and all" do
    run = Run.root(Config.new(tools: [EchoTool]), ~A"acme/assistant")

    assert Run.child(run, name: "echo").config == run.config
  end

  test "a run's own children are siblings" do
    run = Run.root(Config.new(), ~A"acme/assistant")

    one = Run.child(run, name: "one")
    two = Run.child(run, name: "two")

    assert one.source.trace.parent_span_id == two.source.trace.parent_span_id
    assert one.source.trace.span_id != two.source.trace.span_id
  end

  test "child/2 announces nothing" do
    run = subscribed()
    Run.child(run, name: "quiet")

    refute_receive %Event{}
  end

  describe "span/3" do
    test "announces both ends on one child span, and returns the result" do
      run = subscribed()

      assert Run.span(run, "echo", fn _branch -> {:ok, :done} end) == {:ok, :done}

      assert_receive %Event{payload: %Event.SpanStarted{name: "echo"}} = started

      assert_receive %Event{payload: %Event.SpanFinished{outcome: :ok, duration_ms: ms}} =
                       finished

      assert started.source.trace.span_id == finished.source.trace.span_id
      assert started.source.trace.parent_span_id == run.source.trace.span_id
      assert is_integer(ms)
    end

    test "passes the branch run to the function" do
      run = subscribed()

      branch = Run.span(run, "echo", & &1)

      assert branch.source.trace.parent_span_id == run.source.trace.span_id
      assert branch.config == run.config
    end

    test "an error return closes the span as a failure" do
      run = subscribed()

      assert Run.span(run, "echo", fn _ -> {:error, :nope} end) == {:error, :nope}

      assert_receive %Event{payload: %Event.SpanFinished{outcome: {:error, :nope}}}
    end

    test "a raise closes the span and is re-raised" do
      run = subscribed()

      assert_raise RuntimeError, "boom", fn ->
        Run.span(run, "echo", fn _ -> raise "boom" end)
      end

      assert_receive %Event{payload: %Event.SpanFinished{outcome: {:error, %RuntimeError{}}}}
    end

    test "an exit closes the span and is re-raised" do
      run = subscribed()

      catch_exit(Run.span(run, "echo", fn _ -> exit(:crashed) end))

      assert_receive %Event{payload: %Event.SpanFinished{outcome: {:error, :crashed}}}
    end
  end

  describe "open/2 and close/2" do
    test "close a span from a process that did not open it" do
      run = subscribed()
      branch = Run.open(run, "echo")

      assert_receive %Event{payload: %Event.SpanStarted{name: "echo"}}

      task = Task.async(fn -> Run.close(branch, {:error, :timeout}) end)
      Task.await(task)

      assert_receive %Event{payload: %Event.SpanFinished{outcome: {:error, :timeout}}} = finished
      assert finished.source.trace.span_id == branch.source.trace.span_id
    end

    test "closing/2 closes a span opened elsewhere" do
      run = subscribed()

      branch = Run.open(run, "echo")
      assert Run.closing(branch, fn _ -> {:ok, :done} end) == {:ok, :done}

      assert_receive %Event{payload: %Event.SpanStarted{name: "echo"}}
      assert_receive %Event{payload: %Event.SpanFinished{outcome: :ok}}
    end
  end

  describe "who the work is for" do
    test "is the org and user of the agent it runs for" do
      run = Run.root(Config.new(), ~A"acme/@jon/assistant")

      assert %AgentID{org: "acme", user: "jon"} = Run.agent_id(run)
    end

    test "delegated work runs for the same agent" do
      run = Run.root(Config.new(), ~A"acme/@jon/assistant")
      child = Run.child(run, name: "researcher")

      assert Run.agent_id(child) == Run.agent_id(run)
    end
  end

  describe "who asked" do
    test "is the sender named at the root, kept by the work it spawns, and handed to each tool" do
      maria = Wardrik.Principal.new("slack:U1", name: "Maria")
      run = Run.root(Config.new(), ~A"acme/assistant", sender: maria)

      assert Run.child(run, name: "researcher").sender == maria
      assert Wardrik.Test.context(run).sender == maria
    end

    test "is nobody for work nobody asked for" do
      run = Run.root(Config.new(), ~A"acme/assistant")

      assert run.sender == nil
      assert Wardrik.Test.context(run).sender == nil
    end
  end

  describe "deadlines" do
    test "a run without one has all the time in the world" do
      run = Run.root(Config.new(), ~A"acme/assistant")

      assert run.deadline == nil
      assert Run.remaining_ms(run) == :infinity
      refute Run.expired?(run)
    end

    test ":timeout is resolved to an instant once, at the top" do
      run = Run.root(Config.new(), ~A"acme/assistant", timeout: 60_000)

      assert is_integer(run.deadline)
      assert Run.remaining_ms(run) > 55_000
      refute Run.expired?(run)
    end

    test "work cannot award itself more time than it was given" do
      run = Run.root(Config.new(), ~A"acme/assistant", timeout: 1_000)

      widened = Run.with_timeout(run, 600_000)

      assert widened.deadline == run.deadline
      assert Run.remaining_ms(widened) <= 1_000
    end

    test "but it can take less" do
      run = Run.root(Config.new(), ~A"acme/assistant", timeout: 600_000)

      narrowed = Run.with_timeout(run, 1_000)

      assert narrowed.deadline < run.deadline
      assert Run.remaining_ms(narrowed) <= 1_000
    end

    test "a branch narrows its own deadline without touching its parent's" do
      run = Run.root(Config.new(), ~A"acme/assistant", timeout: 600_000)

      branch = Run.child(run, name: "quick", timeout: 1_000)

      assert Run.remaining_ms(branch) <= 1_000
      assert Run.remaining_ms(run) > 500_000
    end

    test "a deadline that has passed reports no time left rather than a negative" do
      run = Run.root(Config.new(), ~A"acme/assistant", timeout: 0)

      assert Run.remaining_ms(run) == 0
      assert Run.expired?(run)
    end

    test "a child inherits the deadline it was started under" do
      run = Run.root(Config.new(), ~A"acme/assistant", timeout: 60_000)

      assert Run.child(run, name: "x").deadline == run.deadline
    end
  end

  describe "the seams a host reaches through" do
    test "hooks default to nothing and are inherited by children" do
      plain = Run.root(Config.new(), ~A"acme/assistant")

      assert plain.hooks == []

      hooks = [%Wardrik.Hook{name: "some", module: SomeHook}]
      wired = Run.root(Config.new(), ~A"acme/assistant", hooks: hooks)

      assert Run.child(wired, name: "branch").hooks == hooks
    end
  end
end
