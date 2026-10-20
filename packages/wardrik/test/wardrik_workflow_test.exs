defmodule WardrikWorkflowTest do
  use ExUnit.Case, async: true

  alias Wardrik.Bus
  alias Wardrik.LLM.Config
  alias Wardrik.Run
  alias WardrikWorkflow.Test.Steps

  setup do
    agent_id = Wardrik.Test.Fleet.id()
    :ok = Bus.subscribe(agent_id)

    {:ok, agent_id: agent_id, run: Run.root(Config.new(), agent_id, name: "turn")}
  end

  defp ok(fun), do: fn input, run -> {:ok, fun.(input, run)} end

  describe "fan_out/4" do
    test "reports one outcome per input, in input order", %{run: run} do
      outcomes =
        WardrikWorkflow.fan_out(run, ["a", "b", "c"], ok(fn input, _run -> input end))

      assert outcomes == [{"a", {:ok, "a"}}, {"b", {:ok, "b"}}, {"c", {:ok, "c"}}]
    end

    test "runs branches at the same time", %{run: run} do
      test_pid = self()

      # No branch may finish until every branch has started, so this only
      # returns if all three are in flight at once.
      barrier =
        ok(fn input, _run ->
          send(test_pid, {:arrived, input, self()})
          receive do: (:go -> input)
        end)

      task = Task.async(fn -> WardrikWorkflow.fan_out(run, 1..3, barrier) end)

      branches =
        for input <- 1..3 do
          assert_receive {:arrived, ^input, branch}, 1_000
          branch
        end

      for branch <- branches, do: send(branch, :go)

      assert Task.await(task) == [{1, {:ok, 1}}, {2, {:ok, 2}}, {3, {:ok, 3}}]
    end

    test "max_concurrency: 1 runs them one at a time", %{run: run} do
      test_pid = self()

      step = ok(fn input, _run -> send(test_pid, {:ran, input}) end)
      WardrikWorkflow.fan_out(run, [:a, :b, :c], step, max_concurrency: 1)

      assert [{:ran, :a}, {:ran, :b}, {:ran, :c}] == drain()
    end

    test "a branch that returns an error is one failed outcome", %{run: run} do
      assert WardrikWorkflow.fan_out(run, [:only], Steps.Boom) == [{:only, {:error, :boom}}]
    end

    test "a branch that crashes is one failed outcome, and the rest still run", %{run: run} do
      step = fn
        :bad, _run -> exit(:crashed)
        input, _run -> {:ok, input}
      end

      {outcomes, _log} =
        ExUnit.CaptureLog.with_log(fn ->
          WardrikWorkflow.fan_out(run, [:good, :bad, :also_good], step)
        end)

      assert [
               {:good, {:ok, :good}},
               {:bad, {:error, :crashed}},
               {:also_good, {:ok, :also_good}}
             ] = outcomes
    end

    test "a branch that runs over time is one failed outcome", %{run: run} do
      step = fn
        :slow, _run -> receive do: (:never -> :ok)
        input, _run -> {:ok, input}
      end

      assert [{:slow, {:error, :timeout}}, {:quick, {:ok, :quick}}] =
               WardrikWorkflow.fan_out(run, [:slow, :quick], step, timeout: 50)
    end

    test "each branch runs under a child of the caller's span", %{run: run} do
      [{_input, {:ok, branch}}] =
        WardrikWorkflow.fan_out(run, [:one], ok(fn _input, run -> run end))

      assert branch.source.agent_id == run.source.agent_id
      assert branch.source.trace.trace_id == run.source.trace.trace_id
      assert branch.source.trace.parent_span_id == run.source.trace.span_id
    end

    test "branches get distinct spans", %{run: run} do
      outcomes = WardrikWorkflow.fan_out(run, [:one, :two], ok(fn _input, run -> run end))
      spans = for {_input, {:ok, run}} <- outcomes, do: run.source.trace.span_id

      assert spans == Enum.uniq(spans)
    end

    test "a string or atom input names its own span", %{run: run} do
      assert [{_input, {:ok, "pricing"}}] =
               WardrikWorkflow.fan_out(run, ["pricing"], Steps.Named)

      assert [{_input, {:ok, "pricing"}}] =
               WardrikWorkflow.fan_out(run, [:pricing], Steps.Named)
    end

    test "anything else falls back to its position", %{run: run} do
      assert [{_a, {:ok, "branch_0"}}, {_b, {:ok, "branch_1"}}] =
               WardrikWorkflow.fan_out(run, [%{a: 1}, %{b: 2}], Steps.Named)
    end

    test "the name option decides the span name", %{run: run} do
      assert [{_input, {:ok, "pricing"}}] =
               WardrikWorkflow.fan_out(run, [%{angle: "pricing"}], Steps.Named, name: & &1.angle)
    end

    test "an empty list of inputs is an empty list of outcomes", %{run: run} do
      assert WardrikWorkflow.fan_out(run, [], Steps.Boom) == []
    end
  end

  describe "sequence/3" do
    test "feeds each step the one before it", %{run: run} do
      steps = [ok(fn n, _run -> n + 1 end), ok(fn n, _run -> n * 10 end)]

      assert WardrikWorkflow.sequence(run, 1, steps) == {:ok, 20}
    end

    test "stops at the first error and leaves later steps unrun", %{run: run} do
      test_pid = self()
      later = ok(fn input, _run -> send(test_pid, :ran_later) && input end)

      assert WardrikWorkflow.sequence(run, :input, [Steps.Boom, later]) == {:error, :boom}
      refute_received :ran_later
    end

    test "each step runs under a child span named after it", %{run: run} do
      assert WardrikWorkflow.sequence(run, nil, [Steps.Named]) == {:ok, "named"}
    end

    test "a function step's span is named for its position", %{run: run} do
      spy = ok(fn _input, run -> run.source.trace.name end)

      assert WardrikWorkflow.sequence(run, nil, [spy]) == {:ok, "step_0"}
    end

    test "no steps returns the input untouched", %{run: run} do
      assert WardrikWorkflow.sequence(run, :untouched, []) == {:ok, :untouched}
    end
  end

  describe "split/1" do
    test "separates what landed from what did not" do
      outcomes = [{:a, {:ok, 1}}, {:b, {:error, :nope}}, {:c, {:ok, 3}}]

      assert WardrikWorkflow.split(outcomes) == {[{:a, 1}, {:c, 3}], [{:b, :nope}]}
    end

    test "keeps input order in both lists" do
      outcomes = [{:a, {:ok, 1}}, {:b, {:ok, 2}}, {:c, {:error, :x}}, {:d, {:error, :y}}]

      assert {[{:a, _}, {:b, _}], [{:c, _}, {:d, _}]} = WardrikWorkflow.split(outcomes)
    end

    test "handles all of one kind" do
      assert WardrikWorkflow.split([]) == {[], []}
      assert WardrikWorkflow.split([{:a, {:ok, 1}}]) == {[{:a, 1}], []}
      assert WardrikWorkflow.split([{:a, {:error, :x}}]) == {[], [{:a, :x}]}
    end
  end

  describe "handle/3" do
    test "runs the step under the run of the context it is handed", %{run: run} do
      assert WardrikWorkflow.handle(Steps.Echo, %{topic: "pricing"}, Wardrik.Test.context(run)) ==
               {:ok, %{"ok" => true, "result" => %{topic: "pricing"}}}
    end

    test "accepts a step with options", %{run: run} do
      assert {:ok, %{"result" => {%{}, [mode: :loud]}}} =
               WardrikWorkflow.handle(
                 {Steps.Echo, [mode: :loud]},
                 %{},
                 Wardrik.Test.context(run)
               )
    end

    test "a failed workflow is an answer, not a failed tool", %{run: run} do
      assert {:ok, %{"ok" => false, "error" => %{"code" => "boom"}}} =
               WardrikWorkflow.handle(Steps.Boom, %{}, Wardrik.Test.context(run))
    end

    test "keyword arguments are accepted", %{run: run} do
      assert {:ok, %{"result" => %{topic: "pricing"}}} =
               WardrikWorkflow.handle(Steps.Echo, [topic: "pricing"], Wardrik.Test.context(run))
    end
  end

  test "nested work keeps one topic and deepens the tree", %{run: run, agent_id: agent_id} do
    inner = fn _input, run ->
      Bus.Event.emit(run.source, %Bus.Result{text: "inner"})
      {:ok, run.source.trace}
    end

    outer = fn _input, run -> {:ok, WardrikWorkflow.fan_out(run, [:leaf], inner)} end

    [{:branch, {:ok, [{:leaf, {:ok, leaf}}]}}] = WardrikWorkflow.fan_out(run, [:branch], outer)

    assert_receive %Bus.Event{payload: %Bus.Result{text: "inner"}} = event
    assert event.source.agent_id == agent_id
    assert leaf.trace_id == run.source.trace.trace_id
    refute leaf.parent_span_id == run.source.trace.span_id
  end

  describe "spans" do
    test "a branch announces both ends of its own span", %{run: run} do
      WardrikWorkflow.fan_out(run, [:only], Steps.Echo)

      assert_receive %Bus.Event{payload: %Bus.SpanStarted{name: "only"}} = started
      assert_receive %Bus.Event{payload: %Bus.SpanFinished{outcome: :ok}} = finished

      assert started.source.trace.span_id == finished.source.trace.span_id
      assert started.source.trace.parent_span_id == run.source.trace.span_id
    end

    test "a branch that errors closes as a failure", %{run: run} do
      WardrikWorkflow.fan_out(run, [:only], Steps.Boom)

      assert_receive %Bus.Event{payload: %Bus.SpanFinished{outcome: {:error, :boom}}}
    end

    test "a branch killed at the timeout is closed by the fan-out", %{run: run} do
      step = fn _input, _run -> receive do: (:never -> :ok) end

      {_outcomes, _log} =
        ExUnit.CaptureLog.with_log(fn ->
          WardrikWorkflow.fan_out(run, [:slow], step, timeout: 20)
        end)

      assert_receive %Bus.Event{payload: %Bus.SpanStarted{name: "slow"}} = started

      assert_receive %Bus.Event{payload: %Bus.SpanFinished{outcome: {:error, :timeout}}} =
                       finished

      assert started.source.trace.span_id == finished.source.trace.span_id
    end

    test "each stage of a sequence announces its own span", %{run: run} do
      WardrikWorkflow.sequence(run, :in, [Steps.Echo, Steps.Echo])

      assert_receive %Bus.Event{payload: %Bus.SpanStarted{name: "echo"}}
      assert_receive %Bus.Event{payload: %Bus.SpanFinished{outcome: :ok}}
      assert_receive %Bus.Event{payload: %Bus.SpanStarted{name: "echo"}}
      assert_receive %Bus.Event{payload: %Bus.SpanFinished{outcome: :ok}}
    end

    test "a sequence stops at the first failed stage", %{run: run} do
      WardrikWorkflow.sequence(run, :in, [Steps.Boom, Steps.Echo])

      assert_receive %Bus.Event{payload: %Bus.SpanFinished{outcome: {:error, :boom}}}
      refute_receive %Bus.Event{payload: %Bus.SpanStarted{name: "echo"}}
    end
  end

  defp drain(acc \\ []) do
    receive do
      {:ran, _input} = message -> drain(acc ++ [message])
    after
      0 -> acc
    end
  end
end
