defmodule Wardrik.AgentLogTest do
  use ExUnit.Case, async: false
  use Mimic

  alias Wardrik.Agent
  alias Wardrik.Event.Log
  alias Wardrik.Event.Log.Entry
  alias Wardrik.Test.AgentRunners
  alias Wardrik.Test.EventLog
  alias Wardrik.Test.LLMStub

  setup :set_mimic_global
  setup :verify_on_exit!

  setup do
    key = Wardrik.Test.Fleet.id("log")
    :ok = Log.subscribe(key)
    %{key: key}
  end

  defp parked_agent(key) do
    {^key, agent} =
      Wardrik.Test.Fleet.start_agent(
        [
          runner: {AgentRunners, :parking, [self(), "call_1"]},
          resumer: {AgentRunners, :resuming, [self(), {:ok, []}]}
        ],
        key
      )

    Agent.ask(agent, "ship it")
    assert_receive %Entry{event: %{"type" => "wardrik.run.interrupted"}}

    agent
  end

  test "a turn's events are written in the order they happened, and followed as they are", %{
    key: key
  } do
    LLMStub.stream([LLMStub.final_answer("Hello.")])
    {^key, agent} = Wardrik.Test.Fleet.start_agent([], key)

    Agent.ask(agent, "hi", id: "m1")
    assert_receive %Entry{event: %{"type" => "wardrik.run.completed"}}

    assert EventLog.types(key) == [
             "wardrik.agent.started",
             "wardrik.message.created",
             "wardrik.run.started",
             "wardrik.message.started",
             "wardrik.message.completed",
             "wardrik.run.completed"
           ]

    assert %{sequence: 6} = Agent.snapshot(agent)

    assert_received %Entry{
      sequence: 3,
      event: %{"type" => "wardrik.run.started", "data" => %{"run" => %{"message_ids" => ["m1"]}}}
    }

    assert_received %Entry{sequence: 4, event: %{"data" => %{"message" => %{"id" => message}}}}

    assert_received %Entry{
      sequence: nil,
      follows: 4,
      event: %{"type" => "wardrik.message.delta", "data" => %{"message" => %{"id" => ^message}}}
    }
  end

  test "a decision is in the log before the run it resumes", %{key: key} do
    agent = parked_agent(key)
    by = Wardrik.Principal.new(:shell, "jon")

    assert :ok =
             Agent.decide(
               agent,
               %{"call_1" => :approve},
               Wardrik.Caller.root(principal: by, host: Wardrik.Host.new())
             )

    assert_receive %Entry{event: %{"type" => "wardrik.run.completed"}}

    assert Enum.drop(EventLog.types(key), 3) == [
             "wardrik.run.interrupted",
             "wardrik.interrupt.resolved",
             "wardrik.run.resumed",
             "wardrik.run.completed"
           ]

    assert {:ok, events} = Log.read(key)

    assert %{"data" => %{"decision" => "approved", "resolved_by" => %{"id" => "jon"}}} =
             Enum.find(events, &(&1["type"] == "wardrik.interrupt.resolved"))
  end

  test "a decision the log cannot record is not taken", %{key: key} do
    agent = parked_agent(key)
    :ok = EventLog.usurp(key)

    assert {:error, :unrecorded} =
             Agent.decide(
               agent,
               %{"call_1" => :approve},
               Wardrik.Caller.root(principal: nil, host: Wardrik.Host.new())
             )

    Agent.resume(agent, %{"call_1" => :approve})
    Agent.ask(agent, "hello?")
    assert [{%{id: "call_1"}, _prompt}] = Agent.parked(agent)
    refute_received {:resumed, _decisions}

    # The message the ask announced reached the agent before this call did.
    Agent.status(agent)
    refute "wardrik.message.created" in Enum.drop(EventLog.types(key), 3)
  end

  test "an agent that comes back goes on numbering where it left off", %{key: key} do
    Wardrik.Test.Fleet.start_agent([], key)
    assert_receive %Entry{sequence: 1, event: %{"data" => %{"conversation" => %{"id" => id}}}}

    :ok = Wardrik.Fleet.stop(key)
    {:ok, _pid} = Wardrik.Fleet.spawn(key, [])

    assert_receive %Entry{
      sequence: 2,
      event: %{"type" => "wardrik.agent.started", "data" => %{"conversation" => %{"id" => ^id}}}
    }
  end

  test "one forgotten and started again under its key never reuses a number", %{key: key} do
    Wardrik.Test.Fleet.start_agent([], key)
    assert_receive %Entry{sequence: 1, event: %{"data" => %{"conversation" => %{"id" => first}}}}

    :ok = Wardrik.Fleet.forget(key)
    Wardrik.Test.Fleet.start_agent([], key)

    assert_receive %Entry{sequence: 2, event: %{"data" => %{"conversation" => %{"id" => second}}}}
    assert first != second
  end
end
