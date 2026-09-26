defmodule Wardrik.Workflow.StepTest do
  use ExUnit.Case, async: true

  alias Wardrik.LLM.Config
  alias Wardrik.Scope
  alias Wardrik.Test.Steps
  alias Wardrik.Workflow.Step

  setup do
    {:ok, scope: Scope.root(Config.new(), Wardrik.Test.Fleet.key(), name: "turn")}
  end

  describe "invoke/3" do
    test "runs a function step", %{scope: scope} do
      assert Step.invoke(fn input, _scope -> {:ok, input * 2} end, 21, scope) == {:ok, 42}
    end

    test "a function step is handed the scope", %{scope: scope} do
      assert Step.invoke(fn _input, given -> {:ok, given} end, nil, scope) == {:ok, scope}
    end

    test "runs a module step with no options", %{scope: scope} do
      assert Step.invoke(Steps.Echo, "hi", scope) == {:ok, "hi"}
    end

    test "runs a module step with options", %{scope: scope} do
      assert Step.invoke({Steps.Echo, [mode: :loud]}, "hi", scope) == {:ok, {"hi", [mode: :loud]}}
    end

    test "passes an error through", %{scope: scope} do
      assert Step.invoke(Steps.Boom, "hi", scope) == {:error, :boom}
    end

    test "anything that is not a result becomes one", %{scope: scope} do
      assert Step.invoke(Steps.Nonsense, "hi", scope) ==
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
      assert Step.name(fn _input, _scope -> :ok end, 3) == "step_3"
    end
  end
end
