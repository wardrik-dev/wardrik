defmodule Tars.WorkflowTest do
  use ExUnit.Case, async: true

  alias Tars.Event
  alias Tars.LLM.Config
  alias Tars.Scope
  alias Tars.Test.Steps
  alias Tars.Workflow

  setup do
    agent_id = make_ref()
    :ok = Event.Bus.subscribe(agent_id)

    {:ok, agent_id: agent_id, scope: Scope.root(Config.new(), agent_id, name: "turn")}
  end

  defp ok(fun), do: fn input, scope -> {:ok, fun.(input, scope)} end

  describe "fan_out/4" do
    test "reports one outcome per input, in input order", %{scope: scope} do
      outcomes = Workflow.fan_out(scope, ["a", "b", "c"], ok(fn input, _scope -> input end))

      assert outcomes == [{"a", {:ok, "a"}}, {"b", {:ok, "b"}}, {"c", {:ok, "c"}}]
    end

    test "runs branches at the same time", %{scope: scope} do
      test_pid = self()

      # No branch may finish until every branch has started, so this only
      # returns if all three are in flight at once.
      barrier =
        ok(fn input, _scope ->
          send(test_pid, {:arrived, input, self()})
          receive do: (:go -> input)
        end)

      task = Task.async(fn -> Workflow.fan_out(scope, 1..3, barrier) end)

      branches =
        for input <- 1..3 do
          assert_receive {:arrived, ^input, branch}, 1_000
          branch
        end

      for branch <- branches, do: send(branch, :go)

      assert Task.await(task) == [{1, {:ok, 1}}, {2, {:ok, 2}}, {3, {:ok, 3}}]
    end

    test "max_concurrency: 1 runs them one at a time", %{scope: scope} do
      test_pid = self()

      step = ok(fn input, _scope -> send(test_pid, {:ran, input}) end)
      Workflow.fan_out(scope, [:a, :b, :c], step, max_concurrency: 1)

      assert [{:ran, :a}, {:ran, :b}, {:ran, :c}] == drain()
    end

    test "a branch that returns an error is one failed outcome", %{scope: scope} do
      assert Workflow.fan_out(scope, [:only], Steps.Boom) == [{:only, {:error, :boom}}]
    end

    test "a branch that crashes is one failed outcome, and the rest still run", %{scope: scope} do
      step = fn
        :bad, _scope -> exit(:crashed)
        input, _scope -> {:ok, input}
      end

      {outcomes, _log} =
        ExUnit.CaptureLog.with_log(fn ->
          Workflow.fan_out(scope, [:good, :bad, :also_good], step)
        end)

      assert [
               {:good, {:ok, :good}},
               {:bad, {:error, :crashed}},
               {:also_good, {:ok, :also_good}}
             ] = outcomes
    end

    test "a branch that runs over time is one failed outcome", %{scope: scope} do
      step = fn
        :slow, _scope -> receive do: (:never -> :ok)
        input, _scope -> {:ok, input}
      end

      assert [{:slow, {:error, :timeout}}, {:quick, {:ok, :quick}}] =
               Workflow.fan_out(scope, [:slow, :quick], step, timeout: 50)
    end

    test "each branch runs under a child of the caller's span", %{scope: scope} do
      [{_input, {:ok, branch}}] =
        Workflow.fan_out(scope, [:one], ok(fn _input, scope -> scope end))

      assert branch.source.agent_id == scope.source.agent_id
      assert branch.source.trace.trace_id == scope.source.trace.trace_id
      assert branch.source.trace.parent_span_id == scope.source.trace.span_id
    end

    test "branches get distinct spans", %{scope: scope} do
      outcomes = Workflow.fan_out(scope, [:one, :two], ok(fn _input, scope -> scope end))
      spans = for {_input, {:ok, scope}} <- outcomes, do: scope.source.trace.span_id

      assert spans == Enum.uniq(spans)
    end

    test "a string or atom input names its own span", %{scope: scope} do
      assert [{_input, {:ok, "pricing"}}] = Workflow.fan_out(scope, ["pricing"], Steps.Named)
      assert [{_input, {:ok, "pricing"}}] = Workflow.fan_out(scope, [:pricing], Steps.Named)
    end

    test "anything else falls back to its position", %{scope: scope} do
      assert [{_a, {:ok, "branch_0"}}, {_b, {:ok, "branch_1"}}] =
               Workflow.fan_out(scope, [%{a: 1}, %{b: 2}], Steps.Named)
    end

    test "the name option decides the span name", %{scope: scope} do
      assert [{_input, {:ok, "pricing"}}] =
               Workflow.fan_out(scope, [%{angle: "pricing"}], Steps.Named, name: & &1.angle)
    end

    test "an empty list of inputs is an empty list of outcomes", %{scope: scope} do
      assert Workflow.fan_out(scope, [], Steps.Boom) == []
    end
  end

  describe "sequence/3" do
    test "feeds each step the one before it", %{scope: scope} do
      steps = [ok(fn n, _scope -> n + 1 end), ok(fn n, _scope -> n * 10 end)]

      assert Workflow.sequence(scope, 1, steps) == {:ok, 20}
    end

    test "stops at the first error and leaves later steps unrun", %{scope: scope} do
      test_pid = self()
      later = ok(fn input, _scope -> send(test_pid, :ran_later) && input end)

      assert Workflow.sequence(scope, :input, [Steps.Boom, later]) == {:error, :boom}
      refute_received :ran_later
    end

    test "each step runs under a child span named after it", %{scope: scope} do
      assert Workflow.sequence(scope, nil, [Steps.Named]) == {:ok, "named"}
    end

    test "a function step's span is named for its position", %{scope: scope} do
      spy = ok(fn _input, scope -> scope.source.trace.name end)

      assert Workflow.sequence(scope, nil, [spy]) == {:ok, "step_0"}
    end

    test "no steps returns the input untouched", %{scope: scope} do
      assert Workflow.sequence(scope, :untouched, []) == {:ok, :untouched}
    end
  end

  describe "split/1" do
    test "separates what landed from what did not" do
      outcomes = [{:a, {:ok, 1}}, {:b, {:error, :nope}}, {:c, {:ok, 3}}]

      assert Workflow.split(outcomes) == {[{:a, 1}, {:c, 3}], [{:b, :nope}]}
    end

    test "keeps input order in both lists" do
      outcomes = [{:a, {:ok, 1}}, {:b, {:ok, 2}}, {:c, {:error, :x}}, {:d, {:error, :y}}]

      assert {[{:a, _}, {:b, _}], [{:c, _}, {:d, _}]} = Workflow.split(outcomes)
    end

    test "handles all of one kind" do
      assert Workflow.split([]) == {[], []}
      assert Workflow.split([{:a, {:ok, 1}}]) == {[{:a, 1}], []}
      assert Workflow.split([{:a, {:error, :x}}]) == {[], [{:a, :x}]}
    end
  end

  describe "call/2" do
    test "runs the step under the scope of the tool call in progress", %{scope: scope} do
      :ok = Scope.Context.put(scope)

      assert Workflow.call(Steps.Echo, %{topic: "pricing"}) ==
               {:ok, %{"ok" => true, "result" => %{topic: "pricing"}}}
    end

    test "accepts a step with options", %{scope: scope} do
      :ok = Scope.Context.put(scope)

      assert {:ok, %{"result" => {%{}, [mode: :loud]}}} =
               Workflow.call({Steps.Echo, [mode: :loud]}, %{})
    end

    test "a failed workflow is an answer, not a failed tool", %{scope: scope} do
      :ok = Scope.Context.put(scope)

      assert {:ok, %{"ok" => false, "error" => %{"code" => "boom"}}} =
               Workflow.call(Steps.Boom, %{})
    end

    test "keyword arguments are accepted", %{scope: scope} do
      :ok = Scope.Context.put(scope)

      assert {:ok, %{"result" => %{topic: "pricing"}}} =
               Workflow.call(Steps.Echo, topic: "pricing")
    end

    test "says so when there is no tool call in progress" do
      # This test's process has never been a tool call.
      assert {:error, message} = Workflow.call(Steps.Echo, %{})
      assert message =~ "outside a tool call"
    end
  end

  test "nested work keeps one topic and deepens the tree", %{scope: scope, agent_id: agent_id} do
    inner = fn _input, scope ->
      Event.emit(scope.source, {:result, "inner"})
      {:ok, scope.source.trace}
    end

    outer = fn _input, scope -> {:ok, Workflow.fan_out(scope, [:leaf], inner)} end

    [{:branch, {:ok, [{:leaf, {:ok, leaf}}]}}] = Workflow.fan_out(scope, [:branch], outer)

    assert_receive %Event{payload: {:result, "inner"}} = event
    assert event.source.agent_id == agent_id
    assert leaf.trace_id == scope.source.trace.trace_id
    refute leaf.parent_span_id == scope.source.trace.span_id
  end

  defp drain(acc \\ []) do
    receive do
      message -> drain(acc ++ [message])
    after
      0 -> acc
    end
  end
end
