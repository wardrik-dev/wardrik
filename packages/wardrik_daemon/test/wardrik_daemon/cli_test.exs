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

  # Runs a command, answering what it printed and how it exited: 0, 1, or
  # :live for one that needs the terminal it came from.
  defp command(args), do: run(&CLI.main/1, args, "")

  # Runs a command live, as over bin/wardrikd rpc, from a terminal someone can
  # type `input` into.
  defp live(args, input \\ ""), do: run(&CLI.live/1, ["--terminal=80,plain,input" | args], input)

  # Arguments are words on a command line, so an ID or a prefix is its text.
  defp run(entry, args, input) do
    parent = self()
    args = Enum.map(args, &to_string/1)

    output =
      capture_io(input, fn ->
        try do
          entry.(args)
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
      Enum.any?(Wardrik.Fleet.list(), &(&1.id == key and &1.status == :parked))
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

    assert_receive %Event{payload: {:call_decided, "call_1", :approve, by}}
    assert Wardrik.Principal.type(by) == :shell
  end

  test "deny refuses the call with the reason given" do
    key = parked_agent()

    assert command(["deny", key, "call_1", "Not", "today."]) == {"Denied call_1 for #{key}.\n", 0}
    assert_receive {:resumed, %{"call_1" => {:deny, "Not today."}}}
  end

  test "a decision nothing is waiting for fails, saying why" do
    key = parked_agent()

    assert command(["approve", key, "call_9"]) == {"#{key} is not waiting on call_9.\n", 1}

    assert {"No agent runs under nobody/here.\n", 1} =
             command(["approve", "nobody/here", "call_1"])
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
             {~s("acme//triage" is not a prefix; a prefix is org/, org/@user/ or an agent ID\n),
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

    assert command(["ask", key, "hello", "there", "--no-wait"]) == {"Asked #{key}.\n", 0}
    assert_receive {:turn, [{:user, "hello there"}]}
  end

  test "ask follows the answer live, and says so where it cannot" do
    {key, _agent} =
      Wardrik.Test.Fleet.start_agent(runner: {AgentRunners, :emitting, ["# Shipped\nall done\n"]})

    assert command(["ask", key, "ship it"]) == {"", :live}
    assert live(["ask", key, "ship", "it"]) == {"Shipped\nall done\n", 0}
  end

  test "ask that parks says what it waits on and how to decide it; one that fails exits 1" do
    {parking, _agent} =
      Wardrik.Test.Fleet.start_agent(runner: {AgentRunners, :parking, [self(), "call_1"]})

    {output, 0} = live(["ask", parking, "deploy"])
    assert output =~ "Waiting on a person for 1 call:\n  ? deploy  call_1"
    assert output =~ "wardrik approve #{parking}, or deny, decides it."

    {failing, _agent} =
      Wardrik.Test.Fleet.start_agent(runner: {AgentRunners, :failing, [:rate_limited]})

    assert live(["ask", failing, "hi"]) == {"✗ the turn failed: :rate_limited\n", 1}
    assert live(["ask", "nobody/here", "hi"]) == {"No agent runs under nobody/here.\n", 1}
  end

  # A live command in a process of its own, writing to a terminal that sends
  # the test each line and stops when told, as Ctrl-C ends the VM a live
  # command writes to.
  defp watching(args) do
    parent = self()
    args = Enum.map(args, &to_string/1)
    terminal = spawn(fn -> terminal(parent) end)

    spawn(fn ->
      Process.group_leader(self(), terminal)
      send(parent, {:watched, CLI.live(args)})
    end)

    terminal
  end

  defp terminal(test) do
    receive do
      {:io_request, from, reply_as, {:put_chars, :unicode, chars}} ->
        send(test, {:written, IO.chardata_to_string(chars)})
        send(from, {:io_reply, reply_as, :ok})
        terminal(test)

      {:io_request, from, reply_as, _request} ->
        send(from, {:io_reply, reply_as, {:error, :enotsup}})
        terminal(test)

      :close ->
        :ok
    end
  end

  test "watch follows an agent's events until its terminal goes" do
    {key, _agent} = Wardrik.Test.Fleet.start_agent()
    terminal = watching(["watch", key])

    assert_receive {:written, "Watching " <> watching}
    assert watching =~ "#{key}, idle on "

    Wardrik.Test.Events.emit(key, {:result, "first\n"})
    Wardrik.Test.Events.emit(key, {:tool_started, "call_1", "deploy", %{}, "key"})
    assert_receive {:written, "first\n"}
    assert_receive {:written, "  → deploy\n"}

    send(terminal, :close)
    assert_receive {:watched, :ok}
    assert command(["watch", key]) == {"", :live}
    assert live(["watch", "nobody/here"]) == {"No agent runs under nobody/here.\n", 1}
  end

  test "watch --json writes each event of the log as a line of JSON" do
    {key, _agent} = Wardrik.Test.Fleet.start_agent()
    :ok = Group.monitor(Wardrik.Event.Log, to_string(key))
    terminal = watching(["watch", key, "--json"])
    assert_receive {:group, [%Group.Event{type: :joined} | _events], _info}

    event = %{"type" => "wardrik.message.delta", "data" => %{"delta" => "hi"}}
    Wardrik.Event.Log.publish(key, %Wardrik.Event.Log.Entry{event: event, follows: 0})
    assert_receive {:written, written}
    assert written == JSON.encode!(event) <> "\n"

    send(terminal, :close)
    assert_receive {:watched, :ok}
  end

  test "approve KEY approves the one call it waits on, and deny KEY asks why" do
    key = parked_agent()
    assert live(["approve", key]) == {"Approved call_1 for #{key}.\n", 0}
    assert_receive {:resumed, %{"call_1" => :approve}}

    key = parked_agent()
    {output, 0} = live(["deny", key], "Not on a Friday.\n")
    assert output =~ "Why? Enter for no reason."
    assert output =~ "Denied call_1 for #{key}."
    assert_receive {:resumed, %{"call_1" => {:deny, "Not on a Friday."}}}
  end

  test "approve alone lists every call waiting, and decides none it is not given" do
    key = parked_agent()
    {output, 0} = live(["approve"], "\n")

    assert output =~ ~r"\d+\. deploy  #{key}  This ships to production."
    assert output =~ "Which to approve?"
    assert output =~ "Nothing was decided."
  end

  test "approve without a call asks which only where someone can answer" do
    key = parked_agent()
    assert command(["approve", key]) == {"", :live}

    assert {"wardrik approve asks which call only where someone can answer" <> _rest, 1} =
             run(&CLI.live/1, ["--terminal=80,plain,no-input", "approve", key], "")

    assert live(["approve", "nobody/here"]) == {"No agent runs under nobody/here.\n", 1}
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

  test "clear empties what has been said" do
    {key, agent} =
      Wardrik.Test.Fleet.start_agent(runner: {AgentRunners, :echo, [self(), "hello back"]})

    :ok = Event.Bus.subscribe(key)
    Agent.ask(agent, "hello")
    assert_receive %Event{payload: {:turn_finished, _messages}}

    assert command(["clear", key]) == {"Cleared #{key}'s conversation.\n", 0}
    assert command(["history", key]) == {"Nothing has been said yet.\n", 0}
    assert command(["clear", "nobody/here"]) == {"No agent runs under nobody/here.\n", 1}
  end

  test "a KEY in the deployment's org may leave the org out, and one that is not a key is refused" do
    test_pid = self()
    name = "bare-#{System.unique_integer([:positive])}"

    {key, _agent} =
      Wardrik.Test.Fleet.start_agent(
        [runner: {AgentRunners, :echo, [test_pid, "hi"]}],
        Wardrik.AgentID.new!(name, org: "default")
      )

    assert to_string(key) == "default/#{name}"
    assert command(["ask", name, "hello", "--no-wait"]) == {"Asked #{key}.\n", 0}
    assert_receive {:turn, [{:user, "hello"}]}

    {mine, _agent} =
      Wardrik.Test.Fleet.start_agent([], Wardrik.AgentID.new!(name, org: "default", user: "jon"))

    assert {_shown, 0} = command(["show", "@jon/#{name}"])
    assert {"Nothing has been said yet.\n", 0} = command(["history", "@jon/#{name}"])
    assert to_string(mine) == "default/@jon/#{name}"

    assert {message, 1} = command(["show", "_#{name}"])
    assert message =~ "_#{name} is not an agent ID"
  end

  test "ask and history on a key nothing holds fail" do
    assert {"No agent runs under nobody/here.\n", 1} =
             command(["ask", "nobody/here", "hi", "--no-wait"])

    assert {"No agent runs under nobody/here.\n", 1} = command(["history", "nobody/here"])
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

  test "ls lists the agents a query picks, with what each is doing and where" do
    parked = parked_agent()
    {idle, _agent} = Wardrik.Test.Fleet.start_agent()

    {output, 0} = command(["ls", parked])
    [heading, row] = output |> String.trim_trailing() |> String.split("\n")
    assert heading =~ ~r"AGENT +STATUS +NODE"
    assert row =~ ~r"#{parked} +parked +#{node()}"

    {output, 0} = command(["ls", "status:parked", "test/"])
    assert output =~ to_string(parked)
    refute output =~ to_string(idle)

    assert command(["ls", idle, "status:parked"]) ==
             {"No agent matches #{idle} status:parked.\n", 0}

    assert {"status:busy is not a word a query takes" <> _rest, 1} =
             command(["ls", "status:busy"])

    {output, 0} = command(["ls", idle, "--json"])
    id = to_string(idle)
    assert %{"agents" => [%{"id" => ^id, "status" => "idle"}]} = JSON.decode!(output)
  end

  test "show gives an agent in full, and what its file gives it" do
    dir = Path.join(System.tmp_dir!(), "wardrik-cli-#{System.unique_integer([:positive])}")
    org = "show-#{System.unique_integer([:positive])}"
    on_exit(fn -> File.rm_rf!(dir) end)
    on_exit(fn -> Wardrik.Fleet.forget_under(Wardrik.AgentID.Prefix.parse!(org <> "/")) end)
    File.mkdir_p!(Path.join(dir, "agents"))

    File.write!(Path.join([dir, "agents", "counter.md"]), """
    ---
    org: #{org}
    description: Counts what it is asked to.
    tools: [web_search]
    policy:
      budget:
        tokens: 500
    schedule:
      name: tally
      every: 30m
      prompt: Count again.
    ---
    You count.
    """)

    start_supervised!({WardrikDaemon.Agents, dir: dir})
    key = Wardrik.AgentID.parse!("#{org}/counter")
    Wardrik.Test.Fleet.await_update(fn -> Wardrik.Fleet.lookup(key) != nil end)

    {output, 0} = command(["show", key])
    assert output =~ "╭─#{key}"
    assert output =~ "Counts what it is asked to."
    assert output =~ ~r"status +idle on #{node()}"
    assert output =~ ~r"tools +web_search"
    assert output =~ ~r"policy +the file's own: no rules; otherwise allow"
    assert output =~ ~r"budget +0 of 500 tokens today"
    assert output =~ ~r"schedule +every 30m +next in \d+m +not run yet"
    assert output =~ Path.join([dir, "agents", "counter.md"])

    parked = parked_agent()
    {output, 0} = command(["show", parked])
    assert output =~ ~r"waiting +call_1 +deploy +This ships to production."
    assert output =~ "none; it was defined over the HTTP API"

    assert command(["show", "nobody/here"]) == {"No agent runs under nobody/here.\n", 1}
  end

  test "schedules lists each schedule's next run, and its last and what came of it" do
    prefix = "cli-#{System.unique_integer([:positive])}/"
    key = Wardrik.AgentID.parse!(prefix <> "pinger")
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
    assert command(["history"]) == {"Usage: wardrik history KEY [--json]\n", 1}

    assert command(["status", "--verbose"]) ==
             {"wardrik status takes no option --verbose\nUsage: wardrik status [--json]\n", 1}
  end

  test "a command the script runs itself is not the daemon's to run" do
    assert command(["serve"]) == {"bin/wardrik runs wardrik serve itself\n", 1}
  end

  test "--json answers with the documents the HTTP API answers with" do
    key = to_string(parked_agent())

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
    {output, 1} = command(["history", "nobody/here", "--json"])

    assert JSON.decode!(output) == %{
             "error" => %{"type" => "failed", "message" => "No agent runs under nobody/here."}
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

  test "__complete answers what can follow, a line each, with the agents running" do
    {key, _agent} = Wardrik.Test.Fleet.start_agent()

    {output, 0} = command(["__complete", "show", key])
    assert output == "#{key}\n"

    assert command(["__complete", "statu"]) == {"status\n", 0}
    assert command(["__complete", "nothing-starts-so"]) == {"", 0}
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

    test "print_offline/2 prints help to standard output, completions without agents, and errors to standard error" do
      assert capture_io(fn -> assert CLI.print_offline(["help", "ls"], %Terminal{}) == 0 end) =~
               "Usage: wardrik ls [QUERY]"

      assert capture_io(fn ->
               assert CLI.print_offline(["__complete", "show", ""], %Terminal{}) == 0
             end) == ""

      assert capture_io(fn ->
               assert CLI.print_offline(["__complete", "statu"], %Terminal{}) == 0
             end) == "status\n"

      assert capture_io(:stderr, fn -> assert CLI.print_offline(["parked"], %Terminal{}) == 1 end) ==
               "wardrik is not running\n"
    end

    test "completion writes the script for a shell, and says which it writes for" do
      {:ok, script} = unanswered(["completion", "fish"])
      assert script =~ "complete -c $name"

      assert unanswered(["completion", "tcsh"]) ==
               {:error, "wardrik completion writes for bash, zsh, fish"}

      assert unanswered(["completion"]) == {:error, "Usage: wardrik completion SHELL"}
    end

    test "a command the daemon answers is one no daemon is running for" do
      assert unanswered(["parked"]) == {:error, "wardrik is not running"}

      assert unanswered(["stauts"]) ==
               {:error, "wardrik: no command stauts; did you mean status or start?"}
    end
  end
end
