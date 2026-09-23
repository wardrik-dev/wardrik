defmodule TarsDaemon.CLITest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias ReqLLM.Context
  alias Tars.Agent
  alias Tars.Event
  alias Tars.Test.AgentRunners
  alias TarsDaemon.CLI

  # Runs a command, answering what it printed and whether it exited.
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

  defp parked_agent do
    test_pid = self()
    answer = {:ok, [Context.assistant("shipped")]}

    {key, agent} =
      Tars.Test.Fleet.start_agent(
        runner: {AgentRunners, :parking, [test_pid, "call_1"]},
        resumer: {AgentRunners, :resuming, [test_pid, answer]}
      )

    :ok = Event.Bus.subscribe(key)
    Agent.ask(agent, "ship it")
    assert_receive %Event{payload: {:turn_parked, _calls}}

    Tars.Test.Fleet.await_update(fn ->
      Enum.any?(Tars.Fleet.list(), &(&1.key == key and &1.status == :parked))
    end)

    key
  end

  test "parked lists each call waiting on a person" do
    key = parked_agent()

    {output, 0} = command(["parked"])

    assert output =~ "#{key}  call_1  deploy  This ships to production."
  end

  test "approve runs the call, and the agent carries on" do
    key = parked_agent()

    assert command(["approve", key, "call_1"]) == {"Approved call_1 for #{key}.\n", 0}
    assert_receive {:resumed, %{"call_1" => :approve}}
  end

  test "deny refuses the call with the reason given" do
    key = parked_agent()

    assert command(["deny", key, "call_1", "Not", "today."]) == {"Denied call_1 for #{key}.\n", 0}
    assert_receive {:resumed, %{"call_1" => {:deny, "Not today."}}}
  end

  test "a decision nothing is waiting for fails, saying why" do
    key = parked_agent()

    assert command(["approve", key, "call_9"]) == {"#{key} is not waiting on call_9.\n", 1}

    assert {"No agent runs under nobody/_/here.\n", 1} =
             command(["approve", "nobody/_/here", "call_1"])
  end

  test "an unknown command fails" do
    assert {"tars: no command frobnicate\n", 1} = command(["frobnicate"])
  end
end
