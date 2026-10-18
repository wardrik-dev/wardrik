defmodule WardrikWorkflow.StepTest do
  use ExUnit.Case, async: true

  alias Wardrik.LLM.Config
  alias Wardrik.Run
  alias WardrikWorkflow.Step
  alias WardrikWorkflow.Test.Steps

  setup do
    {:ok, run: Run.root(Config.new(), Wardrik.Test.Fleet.id(), name: "turn")}
  end

  describe "invoke/3" do
    test "runs a function step", %{run: run} do
      assert Step.invoke(fn input, _run -> {:ok, input * 2} end, 21, run) == {:ok, 42}
    end

    test "a function step is handed the run", %{run: run} do
      assert Step.invoke(fn _input, given -> {:ok, given} end, nil, run) == {:ok, run}
    end

    test "runs a module step with no options", %{run: run} do
      assert Step.invoke(Steps.Echo, "hi", run) == {:ok, "hi"}
    end

    test "runs a module step with options", %{run: run} do
      assert Step.invoke({Steps.Echo, [mode: :loud]}, "hi", run) == {:ok, {"hi", [mode: :loud]}}
    end

    test "passes an error through", %{run: run} do
      assert Step.invoke(Steps.Boom, "hi", run) == {:error, :boom}
    end

    test "anything that is not a result becomes one", %{run: run} do
      assert Step.invoke(Steps.Nonsense, "hi", run) ==
               {:error, {:invalid_step_result, :whatever}}
    end
  end

  describe "name/2" do
    test "names a module after its last segment" do
      assert Step.name(Steps.Echo, 0) == "echo"
      assert Step.name(Wardrik.Test.SearchTool, 0) == "search_tool"
    end

    test "names a module with options the same way" do
      assert Step.name({Steps.Echo, [mode: :loud]}, 0) == "echo"
    end

    test "falls back to position for a function" do
      assert Step.name(fn _input, _run -> :ok end, 3) == "step_3"
    end
  end
end
