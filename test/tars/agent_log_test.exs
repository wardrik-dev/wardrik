defmodule Tars.AgentLogTest do
  use ExUnit.Case, async: false
  use Mimic

  alias Tars.Agent
  alias Tars.Event.Log
  alias Tars.Event.Log.Entry
  alias Tars.Test.AgentRunners
  alias Tars.Test.EventLog
  alias Tars.Test.LLMStub

  setup :set_mimic_global
  setup :verify_on_exit!

  setup do
    key = Tars.Test.Fleet.key("log")
    :ok = Log.subscribe(key)
    %{key: key}
  end

  defp parked_agent(key) do
    {^key, agent} =
      Tars.Test.Fleet.start_agent(
        [
          runner: {AgentRunners, :parking, [self(), "call_1"]},
          resumer: {AgentRunners, :resuming, [self(), {:ok, []}]}
        ],
        key
      )

    Agent.ask(agent, "ship it")
    assert_receive %Entry{event: %{"type" => "tars.run.interrupted"}}

    agent
  end

  test "a turn's events are written in the order they happened, and followed as they are", %{
    key: key
  } do
    LLMStub.stream([LLMStub.final_answer("Hello.")])
    {^key, agent} = Tars.Test.Fleet.start_agent([], key)

    Agent.ask(agent, "hi", id: "m1")
    assert_receive %Entry{event: %{"type" => "tars.run.completed"}}

    assert EventLog.types(key) == [
             "tars.agent.started",
             "tars.message.created",
             "tars.run.started",
             "tars.message.started",
             "tars.message.completed",
             "tars.run.completed"
           ]

    assert %{sequence: 6} = Agent.snapshot(agent)

    assert_received %Entry{
      sequence: 3,
      event: %{"type" => "tars.run.started", "data" => %{"run" => %{"message_ids" => ["m1"]}}}
    }

    assert_received %Entry{sequence: 4, event: %{"data" => %{"message" => %{"id" => message}}}}

    assert_received %Entry{
      sequence: nil,
      follows: 4,
      event: %{"type" => "tars.message.delta", "data" => %{"message" => %{"id" => ^message}}}
    }
  end

  test "a decision is in the log before the run it resumes", %{key: key} do
    agent = parked_agent(key)
    by = %Tars.Principal{type: :shell, id: "jon"}

    assert :ok = Agent.decide(agent, %{"call_1" => :approve}, by: by)
    assert_receive %Entry{event: %{"type" => "tars.run.completed"}}

    assert Enum.drop(EventLog.types(key), 3) == [
             "tars.run.interrupted",
             "tars.interrupt.resolved",
             "tars.run.resumed",
             "tars.run.completed"
           ]

    assert {:ok, events} = Log.read(key)

    assert %{"data" => %{"decision" => "approved", "resolved_by" => %{"id" => "jon"}}} =
             Enum.find(events, &(&1["type"] == "tars.interrupt.resolved"))
  end

  test "a decision the log cannot record is not taken", %{key: key} do
    agent = parked_agent(key)
    :ok = EventLog.usurp(key)

    assert {:error, :unrecorded} = Agent.decide(agent, %{"call_1" => :approve})

    Agent.resume(agent, %{"call_1" => :approve})
    Agent.ask(agent, "hello?")
    assert [{%{id: "call_1"}, _prompt}] = Agent.parked(agent)
    refute_received {:resumed, _decisions}

    # The message the ask announced reached the agent before this call did.
    Agent.status(agent)
    refute "tars.message.created" in Enum.drop(EventLog.types(key), 3)
  end

  test "an agent that comes back goes on numbering where it left off", %{key: key} do
    Tars.Test.Fleet.start_agent([], key)
    assert_receive %Entry{sequence: 1, event: %{"data" => %{"conversation" => %{"id" => id}}}}

    :ok = Tars.Fleet.stop(key)
    {:ok, _pid} = Tars.Fleet.spawn(key, [])

    assert_receive %Entry{
      sequence: 2,
      event: %{"type" => "tars.agent.started", "data" => %{"conversation" => %{"id" => ^id}}}
    }
  end

  test "one forgotten and started again under its key never reuses a number", %{key: key} do
    Tars.Test.Fleet.start_agent([], key)
    assert_receive %Entry{sequence: 1, event: %{"data" => %{"conversation" => %{"id" => first}}}}

    :ok = Tars.Fleet.forget(key)
    Tars.Test.Fleet.start_agent([], key)

    assert_receive %Entry{sequence: 2, event: %{"data" => %{"conversation" => %{"id" => second}}}}
    assert first != second
  end
end
