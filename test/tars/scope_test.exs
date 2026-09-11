defmodule Tars.ScopeTest do
  use ExUnit.Case, async: true

  alias Tars.Event
  alias Tars.LLM.Config
  alias Tars.Scope
  alias Tars.Test.EchoTool
  alias Tars.Trace

  defp subscribed do
    agent_id = make_ref()
    :ok = Event.Bus.subscribe(agent_id)
    Scope.root(Config.new(), agent_id, name: "turn")
  end

  test "root/3 pairs a config with a fresh root span" do
    config = Config.new()
    scope = Scope.root(config, :assistant, name: "turn")

    assert scope.config == config
    assert scope.source.agent_id == :assistant
    assert Trace.root?(scope.source.trace)
    assert scope.source.trace.name == "turn"
  end

  test "child/2 keeps the config and topic, and descends a span" do
    scope = Scope.root(Config.new(), :assistant)
    child = Scope.child(scope, name: "echo")

    assert child.config == scope.config
    assert child.source.agent_id == :assistant
    assert child.source.trace.parent_span_id == scope.source.trace.span_id
    assert child.source.trace.name == "echo"
  end

  test "child/2 carries the config, tools and all" do
    scope = Scope.root(Config.new(tools: [EchoTool]), :assistant)

    assert Scope.child(scope, name: "echo").config == scope.config
  end

  test "a scope's own children are siblings" do
    scope = Scope.root(Config.new(), :assistant)

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

      assert_receive %Event{payload: {:span_started, "echo"}} = started
      assert_receive %Event{payload: {:span_finished, :ok, ms}} = finished

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

      assert_receive %Event{payload: {:span_finished, {:error, :nope}, _ms}}
    end

    test "a raise closes the span and is re-raised" do
      scope = subscribed()

      assert_raise RuntimeError, "boom", fn ->
        Scope.span(scope, "echo", fn _ -> raise "boom" end)
      end

      assert_receive %Event{payload: {:span_finished, {:error, %RuntimeError{}}, _ms}}
    end

    test "an exit closes the span and is re-raised" do
      scope = subscribed()

      catch_exit(Scope.span(scope, "echo", fn _ -> exit(:crashed) end))

      assert_receive %Event{payload: {:span_finished, {:error, :crashed}, _ms}}
    end
  end

  describe "open/2 and close/2" do
    test "close a span from a process that did not open it" do
      scope = subscribed()
      branch = Scope.open(scope, "echo")

      assert_receive %Event{payload: {:span_started, "echo"}}

      task = Task.async(fn -> Scope.close(branch, {:error, :timeout}) end)
      Task.await(task)

      assert_receive %Event{payload: {:span_finished, {:error, :timeout}, _ms}} = finished
      assert finished.source.trace.span_id == branch.source.trace.span_id
    end

    test "closing/2 closes a span opened elsewhere" do
      scope = subscribed()

      branch = Scope.open(scope, "echo")
      assert Scope.closing(branch, fn _ -> {:ok, :done} end) == {:ok, :done}

      assert_receive %Event{payload: {:span_started, "echo"}}
      assert_receive %Event{payload: {:span_finished, :ok, _ms}}
    end
  end
end
