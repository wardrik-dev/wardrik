defmodule Tars.LLM.Turn.ParkedModelTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Context
  alias Tars.Call
  alias Tars.LLM.Config
  alias Tars.LLM.Request
  alias Tars.LLM.Turn.Parked

  defp waiting(spec) do
    call = Call.model(Request.new(Config.new(model_spec: spec), Context.new()))
    %{call | state: :waiting, asks: [%Call.Ask{by: "budget", prompt: "Over budget."}]}
  end

  defp model(spec) do
    Parked.model(waiting(spec),
      context: Context.new(),
      acc: [],
      remaining: 3,
      revision: Tars.Hook.revision([])
    )
  end

  test "a turn parked before a model call waits on one call named model" do
    parked = model("anthropic:claude-sonnet-5")

    assert Parked.model?(parked)
    assert Parked.waiting?(parked)

    assert [
             {%{
                name: "model",
                id: "model_" <> _id,
                arguments: %{"model" => "anthropic:claude-sonnet-5"}
              }, "Over budget."}
           ] = Parked.calls(parked)
  end

  test "names the model whichever way the spec writes it" do
    assert [{%{arguments: %{"model" => "zai:glm-5"}}, _}] =
             Parked.calls(model({:zai, model: "glm-5"}))

    assert [{%{arguments: %{"model" => "%{id: 1}"}}, _}] = Parked.calls(model(%{id: 1}))
  end

  test "refuses fields it is missing, or does not have" do
    assert_raise ArgumentError, ~r/revision/, fn ->
      Parked.model(waiting("zai:glm-5"), context: Context.new(), acc: [], remaining: 3)
    end

    assert_raise KeyError, ~r/remainder/, fn ->
      Parked.model(waiting("zai:glm-5"),
        context: Context.new(),
        acc: [],
        remainder: 3,
        revision: Tars.Hook.revision([])
      )
    end
  end

  test "a turn parked at a tool call is not a model park" do
    refute Parked.model?(Tars.Test.AgentRunners.parked_turn("call_1"))
  end
end
