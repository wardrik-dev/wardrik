defmodule WardrikDaemon.CLITest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias ReqLLM.Context
  alias Wardrik.Agent
  alias Wardrik.Event
  alias Wardrik.Test.AgentRunners
  alias WardrikDaemon.CLI

  @token_usage "Usage: wardrik token create NAME (--scope PREFIX | --all) [--can ACTIONS] " <>
                 "[--policy NAME | --unlimited]\n"

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

  # A turn_parked event reaches a subscriber before the fleet lists the agent
  # as parked, and `parked` reads the fleet.
  defp await_parked(key) do
    Wardrik.Test.Fleet.await_update(fn ->
      Enum.any?(Wardrik.Fleet.list(), &(&1.key == key and &1.status == :parked))
    end)
  end

  defp parked_agent do
    test_pid = self()
    answer = {:ok, [Context.assistant("shipped")]}

    {key, agent} =
      Wardrik.Test.Fleet.start_agent(
        runner: {AgentRunners, :parking, [test_pid, "call_1"]},
        resumer: {AgentRunners, :resuming, [test_pid, answer]}
      )

    :ok = Event.Bus.subscribe(key)
    Agent.ask(agent, "ship it")
    assert_receive %Event{payload: {:turn_parked, _calls}}

    await_parked(key)

    key
  end

  test "parked lists each call waiting on a person" do
    key = parked_agent()

    {output, 0} = command(["parked"])

    assert output =~ "#{key}  call_1  deploy  This ships to production."
  end

  test "parked shows the operator where to authorize a call" do
    link = %{url: "https://github.com/login/device", code: "WDJB-MJHT"}

    {key, agent} =
      Wardrik.Test.Fleet.start_agent(
        runner: {AgentRunners, :connecting, [self(), "call_1", link]}
      )

    :ok = Event.Bus.subscribe(key)
    Agent.ask(agent, "open an issue")
    assert_receive %Event{payload: {:turn_parked, _calls}}

    await_parked(key)

    {output, 0} = command(["parked"])

    assert output =~ "#{key}  call_1"
    assert output =~ "enter WDJB-MJHT at https://github.com/login/device"
  end

  test "approve runs the call, and the agent carries on" do
    key = parked_agent()

    assert command(["approve", key, "call_1"]) == {"Approved call_1 for #{key}.\n", 0}
    assert_receive {:resumed, %{"call_1" => :approve}}

    assert_receive %Event{
      payload: {:call_decided, "call_1", :approve, %Wardrik.Principal{type: :shell}}
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
    :ok = Wardrik.Test.EventLog.usurp(key)

    assert command(["approve", key, "call_1"]) ==
             {"#{key} could not record the decision, so it was not taken.\n", 1}
  end

  test "token create prints a token once; list shows it, and revoke stops it working" do
    name = "cli-#{System.unique_integer([:positive])}"

    {output, 0} = command(["token", "create", name, "--scope", "acme/", "--unlimited"])
    [secret, "", line, ""] = String.split(output, "\n")

    assert {:ok, token} = WardrikHTTP.Token.verify(secret)

    assert line ==
             "#{name} (#{token.id}) reaches the agents under acme/, for every action, " <>
               "with no ceiling. This is the only time it is shown."

    {list, 0} = command(["token", "list"])

    assert list =~
             "  #{token.id}  #{name}  the agents under acme/, for every action, with no ceiling  " <>
               "made #{token.created_at}"

    assert command(["token", "revoke", token.id]) == {"Revoked #{token.id}.\n", 0}
    assert command(["token", "revoke", token.id]) == {"No token has the id #{token.id}.\n", 1}
    assert :error = WardrikHTTP.Token.verify(secret)
  end

  test "token create writes a scope as the key prefix it is, and refuses one that is not" do
    {output, 0} = command(["token", "create", "org", "--scope", "acme", "--unlimited"])
    assert output =~ ") reaches the agents under acme/, for every action, with no ceiling."

    assert command(["token", "create", "bad", "--scope", "acme//triage", "--unlimited"]) ==
             {~s("acme//triage" is not a scope; a scope is org/, org/user/ or a key, org/user/name\n),
              1}
  end

  test "token create --all makes a token that reaches every agent" do
    {output, 0} = command(["token", "create", "everywhere", "--all", "--unlimited"])

    assert output =~ "everywhere ("
    assert output =~ ") reaches every agent, for every action, with no ceiling."
  end

  test "token create --can grants only the actions it names" do
    {output, 0} = command(["token", "create", "watcher", "--scope", "acme/", "--can", "read"])
    assert output =~ ") reaches the agents under acme/, to read."

    {output, 0} =
      command(["token", "create", "triage", "--can", "read,message,decide", "--all"])

    assert output =~ ") reaches every agent, to read, message and decide."

    assert {~s("write" is not an action; the actions are read, message, decide, define, serve\n),
            1} = command(["token", "create", "bad", "--all", "--can", "read,write"])

    assert command(["token", "create", "nowhere", "--can", "read"]) == {@token_usage, 1}
  end

  test "token create holds a token that can define to a policy, or to none said outright" do
    assert command(["token", "create", "unsaid", "--all"]) ==
             {"A token that can define agents holds them to a policy: add --policy NAME, " <>
                "one of policies/, or --unlimited to hold them to their own policies alone\n", 1}

    assert {_output, 1} = command(["token", "create", "unsaid", "--all", "--can", "define"])

    assert command(["token", "create", "both", "--all", "--policy", "careful", "--unlimited"]) ==
             {@token_usage, 1}

    assert command(["token", "create", "reader", "--all", "--can", "read", "--policy", "careful"]) ==
             {"--policy holds the agents a token defines, and this one cannot define\n", 1}
  end

  test "token create --policy makes a policy of policies/ the token's ceiling" do
    dir = Path.join(System.tmp_dir!(), "wardrik-cli-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "policies"))
    File.write!(Path.join(dir, "policies/careful.yaml"), "ask: [github/*]\n")
    on_exit(fn -> File.rm_rf!(dir) end)
    start_supervised!({WardrikDaemon.Agents, dir: dir})

    {output, 0} =
      command([
        "token",
        "create",
        "ci",
        "--scope",
        "acme/",
        "--can",
        "define",
        "--policy",
        "careful"
      ])

    [secret, "", line, ""] = String.split(output, "\n")
    assert line =~ ") reaches the agents under acme/, to define, under the ceiling careful."

    assert {:ok, token} = WardrikHTTP.Token.verify(secret)
    [{_path, {:ok, careful}}] = WardrikDaemon.Agents.files()
    assert token.grant.ceiling == WardrikPolicy.hooks(%{careful | name: "ceiling/careful"})

    {list, 0} = command(["token", "list"])

    assert list =~
             "  #{token.id}  ci  the agents under acme/, to define, under the ceiling careful  "

    assert command(["token", "create", "ci", "--all", "--policy", "nope"]) ==
             {"policies/ has no policy nope; it has careful\n", 1}
  end

  test "ask sends the agent a message" do
    test_pid = self()

    {key, _agent} =
      Wardrik.Test.Fleet.start_agent(runner: {AgentRunners, :echo, [test_pid, "hello back"]})

    assert command(["ask", key, "hello", "there"]) == {"Asked #{key}.\n", 0}
    assert_receive {:turn, [{:user, "hello there"}]}
  end

  test "history prints what has been said, and says when nothing has" do
    test_pid = self()

    {key, agent} =
      Wardrik.Test.Fleet.start_agent(runner: {AgentRunners, :echo, [test_pid, "hello back"]})

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
      {WardrikDaemon.Agents,
       dir: System.tmp_dir!() |> Path.join("wardrik-cli-#{System.unique_integer([:positive])}")}
    )

    assert {status, 0} = command(["status"])
    assert status =~ "on #{node()}"
    assert {reloaded, 0} = command(["reload"])
    assert reloaded =~ "on #{node()}"
  end

  test "schedules lists each schedule's next run, and its last and what came of it" do
    prefix = "cli-#{System.unique_integer([:positive])}/"
    key = prefix <> "_/pinger"
    on_exit(fn -> Wardrik.Schedule.sync(key, []) end)

    assert {output, 0} = command(["schedules", prefix])
    assert output == "Nothing is scheduled under #{prefix}.\n"

    :ok = Event.Bus.subscribe(key, level: :lifecycle)
    {:ok, _pid} = Wardrik.Schedule.put(key, "hourly", every: "0 * * * *", prompt: "Ping.")
    {:ok, _pid} = Wardrik.Schedule.put(key, "tick", every: {:interval, 50}, prompt: "Ping.")
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

  test "an unknown command fails, saying what was probably meant" do
    assert {"wardrik: no command frobnicate\n", 1} = command(["frobnicate"])

    assert {"wardrik: no command stauts; did you mean status or start?\n", 1} =
             command(["stauts"])

    assert {"wardrik: no command token craete; did you mean token create?\n", 1} =
             command(["token", "craete"])
  end

  test "a word that names a group of commands lists them" do
    assert {output, 1} = command(["token"])
    assert output =~ "Usage: wardrik token COMMAND"
    assert output =~ "token revoke ID"
  end

  test "a command read against its definition prints its usage where it does not read" do
    assert command(["approve", "acme/_/triage"]) == {"Usage: wardrik approve KEY CALL\n", 1}

    assert command(["status", "--verbose"]) ==
             {"wardrik status takes no option --verbose\nUsage: wardrik status [--json]\n", 1}
  end

  test "a command the script runs itself is not the daemon's to run" do
    assert command(["serve"]) == {"bin/wardrik runs wardrik serve itself\n", 1}
  end

  test "--json answers with the documents the HTTP API answers with" do
    key = parked_agent()

    {output, 0} = command(["status", "--json"])
    assert %{"agents" => agents} = JSON.decode!(output)
    assert %{"id" => ^key, "status" => "parked"} = Enum.find(agents, &(&1["id"] == key))

    {output, 0} = command(["history", key, "--json"])

    assert %{"agent" => %{"id" => ^key}, "interrupts" => [%{"id" => "call_1"}]} =
             JSON.decode!(output)

    {output, 0} = command(["parked", "--json"])
    assert %{"interrupts" => interrupts} = JSON.decode!(output)

    assert %{"id" => "call_1", "reason" => "tool_approval", "agent" => %{"id" => ^key}} =
             Enum.find(interrupts, &(&1["agent"]["id"] == key))
  end

  test "--json answers a failure as an error document" do
    {output, 1} = command(["history", "nobody/_/here", "--json"])

    assert JSON.decode!(output) == %{
             "error" => %{"type" => "failed", "message" => "No agent runs under nobody/_/here."}
           }

    {output, 1} = command(["history", "--json"])

    assert %{"error" => %{"type" => "usage", "message" => "Usage: wardrik history KEY [--json]"}} =
             JSON.decode!(output)
  end

  test "a terminal that takes colour is written to in colour, and one that does not is not" do
    {coloured, 1} = command(["--terminal=100,colour", "token"])
    {plain, 1} = command(["--terminal=100,plain", "token"])

    assert coloured =~ IO.ANSI.bright()
    refute plain =~ "\e["
    assert plain == elem(command(["token"]), 0)
  end

  describe "unanswered/2" do
    alias WardrikDaemon.CLI.Terminal

    defp unanswered(args) do
      {result, text} = CLI.unanswered(args, %Terminal{})
      {result, text |> WardrikConsole.Ansi.chardata(false) |> IO.chardata_to_string()}
    end

    test "help lists every command, and says where the daemon reads its files" do
      {:ok, text} = unanswered(["help"])

      for command <- CLI.commands(), do: assert(text =~ "  #{command.name}")
      assert text =~ "Usage: wardrik [--node NAME] COMMAND"
      assert text =~ WardrikDaemon.Config.config_dir()
      assert unanswered([]) == {:ok, text}
    end

    test "help for a command gives it in full, and for a group lists it" do
      {:ok, text} = unanswered(["help", "token", "create", "--help"])
      assert text =~ "Usage: wardrik token create NAME (--scope PREFIX | --all)"
      assert text =~ "--can ACTIONS limits it"

      assert {:ok, "Usage: wardrik service COMMAND" <> _listing} = unanswered(["help", "service"])

      assert {:ok, "Usage: wardrik serve\n\nRun the daemon" <> _rest} =
               unanswered(["help", "serve"])

      assert {:error, "wardrik: no command nope"} = unanswered(["help", "nope"])
    end

    test "a command the daemon answers is one no daemon is running for" do
      assert unanswered(["parked"]) == {:error, "wardrik is not running"}

      assert unanswered(["stauts"]) ==
               {:error, "wardrik: no command stauts; did you mean status or start?"}
    end
  end
end
