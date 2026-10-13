defmodule Wardrik.ScopeTest do
  use ExUnit.Case, async: true

  alias Wardrik.AgentID
  alias Wardrik.Event
  alias Wardrik.LLM.Config
  alias Wardrik.Scope
  alias Wardrik.Test.EchoTool
  alias Wardrik.Trace

  import Wardrik.AgentID, only: [sigil_A: 2]

  defp subscribed do
    agent_id = Wardrik.Test.Fleet.id()
    :ok = Event.Bus.subscribe(agent_id)
    Scope.root(Config.new(), agent_id, name: "turn")
  end

  test "root/3 pairs a config with a fresh root span" do
    config = Config.new()
    scope = Scope.root(config, ~A"acme/assistant", name: "turn")

    assert scope.config == config
    assert scope.source.agent_id == ~A"acme/assistant"
    assert Trace.root?(scope.source.trace)
    assert scope.source.trace.name == "turn"
  end

  test "child/2 keeps the config and topic, and descends a span" do
    scope = Scope.root(Config.new(), ~A"acme/assistant")
    child = Scope.child(scope, name: "echo")

    assert child.config == scope.config
    assert child.source.agent_id == ~A"acme/assistant"
    assert child.source.trace.parent_span_id == scope.source.trace.span_id
    assert child.source.trace.name == "echo"
  end

  test "child/2 carries the config, tools and all" do
    scope = Scope.root(Config.new(tools: [EchoTool]), ~A"acme/assistant")

    assert Scope.child(scope, name: "echo").config == scope.config
  end

  test "a scope's own children are siblings" do
    scope = Scope.root(Config.new(), ~A"acme/assistant")

    one = Scope.child(scope, name: "one")
    two = Scope.child(scope, name: "two")

    assert one.source.trace.parent_span_id == two.source.trace.parent_span_id
    assert one.source.trace.span_id != two.source.trace.span_id
  end

  test "child/2 announces nothing" do
    scope = subscribed()
    Scope.child(scope, name: "quiet")

    refute_receive %Event{}
  end

  describe "span/3" do
    test "announces both ends on one child span, and returns the result" do
      scope = subscribed()

      assert Scope.span(scope, "echo", fn _branch -> {:ok, :done} end) == {:ok, :done}

      assert_receive %Event{payload: %Event.SpanStarted{name: "echo"}} = started

      assert_receive %Event{payload: %Event.SpanFinished{outcome: :ok, duration_ms: ms}} =
                       finished

      assert started.source.trace.span_id == finished.source.trace.span_id
      assert started.source.trace.parent_span_id == scope.source.trace.span_id
      assert is_integer(ms)
    end

    test "passes the branch scope to the function" do
      scope = subscribed()

      branch = Scope.span(scope, "echo", & &1)

      assert branch.source.trace.parent_span_id == scope.source.trace.span_id
      assert branch.config == scope.config
    end

    test "an error return closes the span as a failure" do
      scope = subscribed()

      assert Scope.span(scope, "echo", fn _ -> {:error, :nope} end) == {:error, :nope}

      assert_receive %Event{payload: %Event.SpanFinished{outcome: {:error, :nope}}}
    end

    test "a raise closes the span and is re-raised" do
      scope = subscribed()

      assert_raise RuntimeError, "boom", fn ->
        Scope.span(scope, "echo", fn _ -> raise "boom" end)
      end

      assert_receive %Event{payload: %Event.SpanFinished{outcome: {:error, %RuntimeError{}}}}
    end

    test "an exit closes the span and is re-raised" do
      scope = subscribed()

      catch_exit(Scope.span(scope, "echo", fn _ -> exit(:crashed) end))

      assert_receive %Event{payload: %Event.SpanFinished{outcome: {:error, :crashed}}}
    end
  end

  describe "open/2 and close/2" do
    test "close a span from a process that did not open it" do
      scope = subscribed()
      branch = Scope.open(scope, "echo")

      assert_receive %Event{payload: %Event.SpanStarted{name: "echo"}}

      task = Task.async(fn -> Scope.close(branch, {:error, :timeout}) end)
      Task.await(task)

      assert_receive %Event{payload: %Event.SpanFinished{outcome: {:error, :timeout}}} = finished
      assert finished.source.trace.span_id == branch.source.trace.span_id
    end

    test "closing/2 closes a span opened elsewhere" do
      scope = subscribed()

      branch = Scope.open(scope, "echo")
      assert Scope.closing(branch, fn _ -> {:ok, :done} end) == {:ok, :done}

      assert_receive %Event{payload: %Event.SpanStarted{name: "echo"}}
      assert_receive %Event{payload: %Event.SpanFinished{outcome: :ok}}
    end
  end

  describe "who the work is for" do
    test "is the org and user of the agent it runs for" do
      scope = Scope.root(Config.new(), ~A"acme/@jon/assistant")

      assert %AgentID{org: "acme", user: "jon"} = Scope.agent_id(scope)
    end

    test "delegated work runs for the same agent" do
      scope = Scope.root(Config.new(), ~A"acme/@jon/assistant")
      child = Scope.child(scope, name: "researcher")

      assert Scope.agent_id(child) == Scope.agent_id(scope)
    end
  end

  describe "who asked" do
    test "is the sender named at the root, kept by the work it spawns, and handed to each tool" do
      maria = Wardrik.Principal.new(:channel, "slack/U1", name: "Maria")
      scope = Scope.root(Config.new(), ~A"acme/assistant", sender: maria)

      assert Scope.child(scope, name: "researcher").sender == maria
      assert Wardrik.Test.context(scope).sender == maria
    end

    test "is nobody for work nobody asked for" do
      scope = Scope.root(Config.new(), ~A"acme/assistant")

      assert scope.sender == nil
      assert Wardrik.Test.context(scope).sender == nil
    end
  end

  describe "deadlines" do
    test "a scope without one has all the time in the world" do
      scope = Scope.root(Config.new(), ~A"acme/assistant")

      assert scope.deadline == nil
      assert Scope.remaining_ms(scope) == :infinity
      refute Scope.expired?(scope)
    end

    test ":timeout is resolved to an instant once, at the top" do
      scope = Scope.root(Config.new(), ~A"acme/assistant", timeout: 60_000)

      assert is_integer(scope.deadline)
      assert Scope.remaining_ms(scope) > 55_000
      refute Scope.expired?(scope)
    end

    test "work cannot award itself more time than it was given" do
      scope = Scope.root(Config.new(), ~A"acme/assistant", timeout: 1_000)

      widened = Scope.with_timeout(scope, 600_000)

      assert widened.deadline == scope.deadline
      assert Scope.remaining_ms(widened) <= 1_000
    end

    test "but it can take less" do
      scope = Scope.root(Config.new(), ~A"acme/assistant", timeout: 600_000)

      narrowed = Scope.with_timeout(scope, 1_000)

      assert narrowed.deadline < scope.deadline
      assert Scope.remaining_ms(narrowed) <= 1_000
    end

    test "a branch narrows its own deadline without touching its parent's" do
      scope = Scope.root(Config.new(), ~A"acme/assistant", timeout: 600_000)

      branch = Scope.child(scope, name: "quick", timeout: 1_000)

      assert Scope.remaining_ms(branch) <= 1_000
      assert Scope.remaining_ms(scope) > 500_000
    end

    test "a deadline that has passed reports no time left rather than a negative" do
      scope = Scope.root(Config.new(), ~A"acme/assistant", timeout: 0)

      assert Scope.remaining_ms(scope) == 0
      assert Scope.expired?(scope)
    end

    test "a child inherits the deadline it was started under" do
      scope = Scope.root(Config.new(), ~A"acme/assistant", timeout: 60_000)

      assert Scope.child(scope, name: "x").deadline == scope.deadline
    end
  end

  describe "the seams a host reaches through" do
    test "hooks and dispatch default to nothing and are inherited by children" do
      plain = Scope.root(Config.new(), ~A"acme/assistant")

      assert plain.hooks == []
      assert plain.dispatch == nil

      hooks = [%Wardrik.Hook{name: "some", module: SomeHook}]
      wired = Scope.root(Config.new(), ~A"acme/assistant", hooks: hooks, dispatch: SomeGateway)
      child = Scope.child(wired, name: "branch")

      assert child.hooks == hooks
      assert child.dispatch == SomeGateway
    end
  end
end
