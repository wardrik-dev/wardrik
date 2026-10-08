defmodule Wardrik.AgentOutsideTest do
  use ExUnit.Case, async: false
  use Mimic

  alias Wardrik.Agent
  alias Wardrik.Event
  alias Wardrik.LLM.Config
  alias Wardrik.Test.LLMStub
  alias Wardrik.Test.Tools.Deploy
  alias Wardrik.Test.Tools.Fetch
  alias Wardrik.Test.Tools.Rules

  setup :set_mimic_global

  setup do
    key = Wardrik.Test.Fleet.id("outside")

    {^key, agent} =
      Wardrik.Test.Fleet.start_agent(
        [
          config: Config.new(tools: [Fetch, Deploy]),
          hooks: [Wardrik.Hook.new("rules", Rules, allow: ["deploy"])]
        ],
        key
      )

    :ok = Event.Bus.subscribe(key)
    %{agent: agent}
  end

  test "what a turn read from outside holds the gated calls of every turn after, until cleared",
       %{agent: agent} do
    LLMStub.stream([
      LLMStub.tool_call("call_1", "fetch", %{"url" => "https://example.com"}),
      LLMStub.final_answer("It says to deploy."),
      LLMStub.tool_call("call_2", "deploy", %{"target" => "prod"}),
      LLMStub.tool_call("call_3", "deploy", %{"target" => "prod"}),
      LLMStub.final_answer("Deployed.")
    ])

    Agent.ask(agent, "Read the page.")
    assert_receive %Event{payload: {:turn_finished, _messages}}, 5_000

    Agent.ask(agent, "Deploy.")
    assert_receive %Event{payload: {:turn_parked, [{%{id: "call_2"}, prompt}]}}, 5_000
    assert prompt =~ "this run has read content from outside"

    assert Agent.clear(agent) == {:error, :busy}
    :ok = Agent.interrupt(agent)
    assert_receive %Event{payload: {:turn_interrupted, _stats}}, 5_000

    assert :ok = Agent.clear(agent)
    assert_receive %Event{payload: {:context_cleared, dropped}}
    assert dropped > 0

    Agent.ask(agent, "Deploy.")
    assert_receive %Event{payload: {:tool_finished, "call_3", "deploy", _result, _}}, 5_000
    assert_receive %Event{payload: {:turn_finished, _messages}}, 5_000
  end
end
