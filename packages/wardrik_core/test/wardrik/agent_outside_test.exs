defmodule Wardrik.AgentOutsideTest do
  use ExUnit.Case, async: false

  alias Wardrik.Agent
  alias Wardrik.Bus
  alias Wardrik.LLM.Config
  alias Wardrik.Test.LLM
  alias Wardrik.Test.Tools.Deploy
  alias Wardrik.Test.Tools.Fetch
  alias Wardrik.Test.Tools.Rules

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

    :ok = Bus.subscribe(key)
    %{agent: agent}
  end

  test "what a turn read from outside holds the gated calls of every turn after, until cleared",
       %{agent: agent} do
    LLM.stream(Wardrik.Test.llm(), [
      LLM.tool_call("call_1", "fetch", %{"url" => "https://example.com"}),
      LLM.final_answer("It says to deploy."),
      LLM.tool_call("call_2", "deploy", %{"target" => "prod"}),
      LLM.tool_call("call_3", "deploy", %{"target" => "prod"}),
      LLM.final_answer("Deployed.")
    ])

    Agent.ask(agent, "Read the page.")
    assert_receive %Bus.Event{payload: %Bus.TurnFinished{}}, 5_000

    Agent.ask(agent, "Deploy.")
    assert_receive %Bus.Event{payload: %Bus.TurnParked{calls: [{%{id: "call_2"}, prompt}]}}, 5_000
    assert prompt =~ "this run has read content from outside"

    assert Agent.clear(agent) == {:error, :busy}
    :ok = Agent.interrupt(agent)
    assert_receive %Bus.Event{payload: %Bus.TurnInterrupted{}}, 5_000

    assert :ok = Agent.clear(agent)
    assert_receive %Bus.Event{payload: %Bus.ContextCleared{dropped: dropped}}
    assert dropped > 0

    Agent.ask(agent, "Deploy.")

    assert_receive %Bus.Event{payload: %Bus.ToolFinished{call_id: "call_3", name: "deploy"}},
                   5_000

    assert_receive %Bus.Event{payload: %Bus.TurnFinished{}}, 5_000
  end

  test "a message from outside holds the gated calls of its turn", %{agent: agent} do
    LLM.stream(Wardrik.Test.llm(), [LLM.tool_call("call_1", "deploy", %{"target" => "prod"})])

    Agent.ask(agent, "Deploy, says someone in a shared channel.", labels: ["outside"])

    assert_receive %Bus.Event{
                     payload: %Bus.TurnParked{
                       calls: [{%{id: "call_1", labels: ["outside"]}, prompt}]
                     }
                   },
                   5_000

    assert prompt =~ "this run has read content from outside"
  end
end
