defmodule Tars.LLM.Turn.WaitingModelTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Context
  alias Tars.Call
  alias Tars.LLM.Config
  alias Tars.LLM.Request
  alias Tars.LLM.Turn

  # A turn waiting before a call to `spec`, as a hook that asked about it
  # leaves one.
  defp waiting(spec) do
    call = Call.model(Request.new(Config.new(model_spec: spec), Context.new()))
    call = %{call | state: :waiting, asks: [%Call.Ask{by: "budget", prompt: "Over budget."}]}

    %Turn{context: Context.new(), calls: [call], remaining: 3, state: :waiting}
  end

  test "a turn waiting before a model call waits on one call named model" do
    turn = waiting("anthropic:claude-sonnet-5")

    assert Turn.model?(turn)

    assert [
             {%{
                name: "model",
                id: "model_" <> _id,
                arguments: %{"model" => "anthropic:claude-sonnet-5"}
              }, "Over budget."}
           ] = Turn.waiting(turn)
  end

  test "names the model whichever way the spec writes it" do
    assert [{%{arguments: %{"model" => "zai:glm-5"}}, _}] =
             Turn.waiting(waiting({:zai, model: "glm-5"}))

    assert [{%{arguments: %{"model" => "%{id: 1}"}}, _}] = Turn.waiting(waiting(%{id: 1}))
  end

  test "a turn waiting at a tool call is not waiting on a model" do
    refute Turn.model?(Tars.Test.AgentRunners.parked_turn("call_1"))
  end
end
