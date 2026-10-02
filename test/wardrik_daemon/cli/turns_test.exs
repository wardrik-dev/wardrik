defmodule WardrikDaemon.CLI.TurnsTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Wardrik.Agent
  alias Wardrik.Event
  alias Wardrik.Test.AgentRunners
  alias Wardrik.Test.Fleet
  alias WardrikDaemon.CLI

  defp command(args) do
    parent = self()

    output =
      capture_io(fn ->
        try do
          CLI.main(args)
          send(parent, {:status, 0})
        catch
          :exit, {:shutdown, code} -> send(parent, {:status, code})
        end
      end)

    assert_receive {:status, status}
    {output, status}
  end

  defp running(key \\ Fleet.key()) do
    {key, _pid} =
      Fleet.start_agent([runner: {AgentRunners, :streaming, [self()]}], key)

    :ok = Event.Bus.subscribe(key, level: :lifecycle)
    :ok = Agent.ask(key, "Go on.")
    assert_receive {:running, _turn}
    key
  end

  test "stops a running turn, and drops what waits behind it" do
    key = running()
    :ok = Agent.ask(key, "And then this.")
    assert_receive %Event{payload: {:message_queued, _message}}

    assert command(["cancel", key]) ==
             {"Stopped #{key}, and dropped 1 message waiting behind it.\n", 0}

    assert_receive %Event{payload: {:turn_interrupted, _stats}}
    assert %{state: :idle, pending: 0} = Agent.status(key)
  end

  test "abandons a turn waiting on a person" do
    {key, _pid} =
      Fleet.start_agent(runner: {AgentRunners, :parking, [self(), "call_1"]})

    :ok = Event.Bus.subscribe(key, level: :lifecycle)
    :ok = Agent.ask(key, "Ship it.")
    assert_receive %Event{payload: {:turn_parked, _calls}}

    assert command(["cancel", key]) ==
             {"Stopped #{key}, and abandoned the calls it waited on.\n", 0}

    assert_receive %Event{payload: {:turn_interrupted, _stats}}
    assert Agent.parked(key) == []
  end

  test "says when an agent was doing nothing, and when no agent runs under a key" do
    {key, _pid} = Fleet.start_agent()

    assert command(["cancel", key]) == {"#{key} was doing nothing.\n", 0}
    assert command(["cancel", "nobody/here"]) == {"No agent runs under nobody/here.\n", 1}
  end

  test "stops every agent under a prefix" do
    prefix = "test/@u#{System.unique_integer([:positive])}/"
    running(prefix <> "one")
    running(prefix <> "two")

    assert command(["cancel", prefix]) == {"Stopped 2 agents under #{prefix}.\n", 0}
    assert_receive %Event{payload: {:turn_interrupted, _stats}}
    assert_receive %Event{payload: {:turn_interrupted, _stats}}

    assert command(["cancel", "test/@nobody-here/"]) ==
             {"No agent runs under test/@nobody-here/.\n", 1}
  end

  test "stops every agent with --all, and wants a key, a prefix or --all alone" do
    key = running()

    assert {"Stopped " <> _count, 0} = command(["cancel", "--all"])
    assert_receive %Event{payload: {:turn_interrupted, _stats}}
    assert %{state: :idle} = Agent.status(key)

    assert {_usage, 1} = command(["cancel"])
    assert {_usage, 1} = command(["cancel", key, "--all"])
  end
end
