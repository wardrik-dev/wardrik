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

    assert_receive %Event{
      payload: {:call_decided, "call_1", :approve, %Tars.Principal{type: :shell}}
    }
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

  test "a decision the agent cannot record fails, saying so" do
    key = parked_agent()
    :ok = Tars.Test.EventLog.usurp(key)

    assert command(["approve", key, "call_1"]) ==
             {"#{key} could not record the decision, so it was not taken.\n", 1}
  end

  test "token create prints a token once; list shows it, and revoke stops it working" do
    name = "cli-#{System.unique_integer([:positive])}"

    {output, 0} = command(["token", "create", name, "--scope", "acme/"])
    [secret, "", line, ""] = String.split(output, "\n")

    assert {:ok, token} = TarsHTTP.Token.verify(secret)

    assert line ==
             "#{name} (#{token.id}) reaches the agents under acme/, for every action. " <>
               "This is the only time it is shown."

    {list, 0} = command(["token", "list"])

    assert list =~
             "  #{token.id}  #{name}  the agents under acme/, for every action  " <>
               "made #{token.created_at}"

    assert command(["token", "revoke", token.id]) == {"Revoked #{token.id}.\n", 0}
    assert command(["token", "revoke", token.id]) == {"No token has the id #{token.id}.\n", 1}
    assert :error = TarsHTTP.Token.verify(secret)
  end

  test "token create writes a scope as the key prefix it is, and refuses one that is not" do
    {output, 0} = command(["token", "create", "org", "--scope", "acme"])
    assert output =~ ") reaches the agents under acme/, for every action."

    assert command(["token", "create", "bad", "--scope", "acme//triage"]) ==
             {~s("acme//triage" is not a scope; a scope is org/, org/user/ or a key, org/user/name\n),
              1}
  end

  test "token create --all makes a token that reaches every agent" do
    {output, 0} = command(["token", "create", "everywhere", "--all"])

    assert output =~ "everywhere ("
    assert output =~ ") reaches every agent, for every action."
  end

  test "token create --can grants only the actions it names" do
    {output, 0} = command(["token", "create", "watcher", "--scope", "acme/", "--can", "read"])
    assert output =~ ") reaches the agents under acme/, to read."

    {output, 0} =
      command(["token", "create", "triage", "--can", "read,message,decide", "--all"])

    assert output =~ ") reaches every agent, to read, message and decide."

    assert {~s("write" is not an action; the actions are read, message, decide, define, serve\n),
            1} = command(["token", "create", "bad", "--all", "--can", "read,write"])

    assert command(["token", "create", "nowhere", "--can", "read"]) ==
             {"tars: token create NAME (--scope PREFIX | --all) [--can ACTIONS]\n", 1}
  end

  test "ask sends the agent a message" do
    test_pid = self()

    {key, _agent} =
      Tars.Test.Fleet.start_agent(runner: {AgentRunners, :echo, [test_pid, "hello back"]})

    assert command(["ask", key, "hello", "there"]) == {"Asked #{key}.\n", 0}
    assert_receive {:turn, [{:user, "hello there"}]}
  end

  test "history prints what has been said, and says when nothing has" do
    test_pid = self()

    {key, agent} =
      Tars.Test.Fleet.start_agent(runner: {AgentRunners, :echo, [test_pid, "hello back"]})

    assert command(["history", key]) == {"Nothing has been said yet.\n", 0}

    :ok = Event.Bus.subscribe(key)
    Agent.ask(agent, "hello")
    assert_receive %Event{payload: {:turn_finished, _messages}}

    assert command(["history", key]) == {"user: hello\n\nassistant: hello back\n", 0}
  end

  test "ask and history on a key nothing holds fail" do
    assert {"No agent runs under nobody/_/here.\n", 1} = command(["ask", "nobody/_/here", "hi"])
    assert {"No agent runs under nobody/_/here.\n", 1} = command(["history", "nobody/_/here"])
  end

  test "status and reload answer with the node's state" do
    start_supervised!(
      {TarsDaemon.Agents,
       dir: System.tmp_dir!() |> Path.join("tars-cli-#{System.unique_integer([:positive])}")}
    )

    assert {status, 0} = command(["status"])
    assert status =~ "on #{node()}"
    assert {reloaded, 0} = command(["reload"])
    assert reloaded =~ "on #{node()}"
  end

  test "schedules lists each schedule's next run, and its last and what came of it" do
    prefix = "cli-#{System.unique_integer([:positive])}/"
    key = prefix <> "_/pinger"
    on_exit(fn -> Tars.Schedule.sync(key, []) end)

    assert {output, 0} = command(["schedules", prefix])
    assert output == "Nothing is scheduled under #{prefix}.\n"

    :ok = Event.Bus.subscribe(key, level: :lifecycle)
    {:ok, _pid} = Tars.Schedule.put(key, "hourly", every: "0 * * * *", prompt: "Ping.")
    {:ok, _pid} = Tars.Schedule.put(key, "tick", every: {:interval, 50}, prompt: "Ping.")
    # A schedule announces a firing before it records it, so the second
    # firing is the first that finds the one before it written down.
    assert_receive %Event{payload: {:schedule_fired, "tick", :no_agent}}
    assert_receive %Event{payload: {:schedule_fired, "tick", :no_agent}}

    assert {output, 0} = command(["schedules", prefix])
    assert output =~ "2 schedules:"
    assert output =~ ~r"  #{key}/hourly  0 \* \* \* \*  next in \d+[ms]  not run yet"

    assert output =~
             ~r"  #{key}/tick  every 50ms  next in \d+s  last run \d+s ago: no agent runs under the key"
  end

  test "an unknown command fails" do
    assert {"tars: no command frobnicate\n", 1} = command(["frobnicate"])
  end
end
