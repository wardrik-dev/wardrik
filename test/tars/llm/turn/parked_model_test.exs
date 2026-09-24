defmodule Tars.LLM.Turn.ParkedModelTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Context
  alias Tars.LLM.Turn.Parked

  defp model(spec), do: Parked.model(Context.new(), spec, "Over budget.", [], 3)

  test "a turn parked before a model call waits on one call named model" do
    parked = model("anthropic:claude-sonnet-5")

    assert Parked.model?(parked)
    assert Parked.waiting?(parked)

    assert [
             {%{name: "model", arguments: %{"model" => "anthropic:claude-sonnet-5"}},
              "Over budget."}
           ] =
             Parked.calls(parked)
  end

  test "names the model whichever way the spec writes it" do
    assert [{%{arguments: %{"model" => "zai:glm-5"}}, _}] =
             Parked.calls(model({:zai, model: "glm-5"}))

    assert [{%{arguments: %{"model" => "%{id: 1}"}}, _}] = Parked.calls(model(%{id: 1}))
  end

  test "a turn parked at a tool call is not a model park" do
    refute Parked.model?(Tars.Test.AgentRunners.parked_turn("call_1"))
  end
end
