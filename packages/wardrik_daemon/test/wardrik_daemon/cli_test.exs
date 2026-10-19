defmodule WardrikDaemon.CLITest do
  use ExUnit.Case, async: false

  alias Wardrik.Test.Script
  alias WardrikDaemon.Test.Host

  # Commands run over rpc build their callers on the daemon's host.
  setup do
    Host.declare(["acme"])
    Host.held()
  end

  import ExUnit.CaptureIO

  alias Wardrik.Agent
  alias Wardrik.Event
  alias Wardrik.Test.AgentRunners
  alias Wardrik.Test.Audit
  alias WardrikDaemon.CLI

  @token_usage "Usage: wardrik token create NAME --resource PATTERN... --role ROLES " <>
                 "[--policy NAME] [--expires 30d]\n"

  @ops %{"id" => "shell:ops"}

  # Runs a command, answering what it printed and how it exited: 0, 1, or
  # :live for one that needs the terminal it came from.
  # Each is typed by the account ops, unless it says otherwise.
  defp command(["--terminal=" <> _described | _args] = args), do: run(&CLI.main/1, args, "")
  defp command(args), do: command(["--terminal=80,plain,no-input,user=ops" | args])

  # Runs a command live, as over bin/wardrikd rpc, from a terminal someone can
  # type `input` into.
  defp live(args, input \\ ""),
    do: run(&CLI.live/1, ["--terminal=80,plain,input,user=ops" | args], input)

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
      Enum.any?(
        Wardrik.Fleet.list(Wardrik.Resource.parse!("*"), host: Host.host()),
        &(&1.id == key and &1.status == :parked)
      )
    end)
  end

  defp parked_agent do
    test_pid = self()
    answer = {:ok, [Wardrik.Conversation.Assistant.new("shipped")]}

    {key, agent} =
      Wardrik.Test.Fleet.start_agent(
        config:
          Script.new({AgentRunners, :parking, [test_pid, "call_1"]},
            resume: {AgentRunners, :resuming, [test_pid, answer]}
          )
      )

    :ok = Event.Bus.subscribe(key)
    Agent.ask(agent, "ship it", host: Host.host())
    assert_receive %Event{payload: %Event.TurnParked{}}

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
        config: Script.new({AgentRunners, :connecting, [self(), "call_1", link]})
      )

    :ok = Event.Bus.subscribe(key)
    Agent.ask(agent, "open an issue", host: Host.host())
    assert_receive %Event{payload: %Event.TurnParked{}}

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
      payload: %Event.CallDecided{call_id: "call_1", decision: :approve, by: by}
    }

    assert by == Wardrik.Principal.new("shell:ops")
  end

  test "approve hands the agent the note given" do
    key = parked_agent()

    assert command(["approve", key, "call_1", "Only", "staging."]) ==
             {"Approved call_1 for #{key}.\n", 0}

    assert_receive {:resumed, %{"call_1" => {:approve, "Only staging."}}}
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

    {output, 0} =
      command(["token", "create", name, "--resource", "acme/agent/*", "--role", "owner"])

    [secret, "", line, ""] = String.split(output, "\n")

    assert {:ok, token} = WardrikHTTP.Token.verify(Wardrik.Test.store(), secret)
    assert %Wardrik.Token{principal: principal} = token.token
    assert Wardrik.Principal.id(principal) == "shell:ops"

    assert line ==
             "#{name} (#{token.id}) allows owner on acme/agent/*, " <>
               "until #{DateTime.to_iso8601(token.token.expires)}. This is the only time it is shown."

    {list, 0} = command(["token", "list"])

    assert list =~
             "  #{token.id}  #{name}  owner on acme/agent/*, until " <>
               "#{DateTime.to_iso8601(token.token.expires)}  " <>
               "made #{DateTime.to_iso8601(token.created_at)}"

    assert command(["token", "revoke", token.id]) == {"Revoked #{token.id}.\n", 0}
    assert command(["token", "revoke", token.id]) == {"No token has the id #{token.id}.\n", 1}
    assert :error = WardrikHTTP.Token.verify(Wardrik.Test.store(), secret)

    assert [
             %{"type" => "wardrik.token.created", "data" => created},
             %{"type" => "wardrik.token.revoked", "data" => %{"actor" => @ops}}
           ] =
             for(
               %{"subject" => subject} = e <- Audit.all(),
               subject == "deployment/token/#{token.id}",
               do: e
             )

    assert %{
             "token" => %{"name" => ^name},
             "principal" => @ops,
             "statements" => [%{"actions" => ["*"], "resources" => ["acme/agent/*"]}],
             "actor" => @ops
           } = created

    refute Map.has_key?(created, "secret")
  end

  test "token create allows the roles it names, for as long as --expires says" do
    {output, 0} =
      command([
        "token",
        "create",
        "watcher",
        "--resource",
        "acme/agent/*",
        "--role",
        "reader,messenger"
      ])

    assert output =~ ") allows reader, messenger on acme/agent/*, until "

    {output, 0} =
      command([
        "token",
        "create",
        "brief",
        "--resource",
        "*",
        "--role",
        "approver",
        "--expires",
        "1h"
      ])

    [secret | _rest] = String.split(output, "\n")
    assert {:ok, token} = WardrikHTTP.Token.verify(Wardrik.Test.store(), secret)
    assert output =~ ") allows approver on *, until "
    assert_in_delta DateTime.diff(token.token.expires, DateTime.utc_now()), 3600, 5

    assert {~s(--role: "writer" is not a role; the roles are reader, messenger, approver, ) <>
              "definer, worker, owner\n", 1} =
             command(["token", "create", "bad", "--resource", "*", "--role", "reader,writer"])

    assert command(["token", "create", "nowhere", "--role", "reader"]) == {@token_usage, 1}
    assert command(["token", "create", "nothing", "--resource", "*"]) == {@token_usage, 1}

    assert command([
             "token",
             "create",
             "never",
             "--resource",
             "*",
             "--role",
             "owner",
             "--expires",
             "soon"
           ]) ==
             {"--expires is how long it works, as 30d, 12h, 30m or 45s\n", 1}
  end

  test "token create takes each --resource as the pattern it is, and refuses one that is not" do
    {output, 0} =
      command([
        "token",
        "create",
        "two",
        "--resource",
        "acme/agent/*",
        "--resource",
        "acme/@jon/*",
        "--role",
        "owner"
      ])

    assert output =~ ") allows owner on acme/agent/*, acme/@jon/*, until "

    {output, 0} =
      command(["token", "create", "tenant", "--resource", "acme/*", "--role", "owner"])

    assert output =~ ") allows owner on acme/*, until "

    assert command(["token", "create", "typo", "--resource", "acmee/*", "--role", "owner"]) ==
             {"--resource: acmee is not an org config.yaml declares: default, acme; " <>
                "did you mean acme?\n", 1}

    assert {"--resource: \"acme//triage\" is not a resource" <> _rest, 1} =
             command(["token", "create", "bad", "--resource", "acme//triage", "--role", "owner"])
  end

  test "token create --policy makes a policy of policies/ the token's policy" do
    dir = Path.join(System.tmp_dir!(), "wardrik-cli-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "policies"))
    File.write!(Path.join(dir, "policies/careful.yaml"), "ask: [github/*]\n")
    on_exit(fn -> File.rm_rf!(dir) end)
    Host.start_agents(dir)

    {output, 0} =
      command([
        "token",
        "create",
        "ci",
        "--resource",
        "acme/agent/*",
        "--role",
        "definer",
        "--policy",
        "careful"
      ])

    [secret, "", line, ""] = String.split(output, "\n")
    assert line =~ ") allows definer on acme/agent/*, under the policy careful, until "

    assert {:ok, token} = WardrikHTTP.Token.verify(Wardrik.Test.store(), secret)
    assert token.token.policy == "careful"

    {list, 0} = command(["token", "list"])
    assert list =~ "  #{token.id}  ci  definer on acme/agent/*, under the policy careful, until "

    assert command([
             "token",
             "create",
             "ci",
             "--resource",
             "*",
             "--role",
             "owner",
             "--policy",
             "nope"
           ]) ==
             {"policies/ has no policy nope; it has careful\n", 1}
  end

  test "ask sends the agent a message, from whoever typed it" do
    test_pid = self()

    {key, _agent} =
      Wardrik.Test.Fleet.start_agent(
        config: Script.new({AgentRunners, :echo, [test_pid, "hello back"]})
      )

    assert command(["ask", key, "hello", "there", "--no-wait"]) == {"Asked #{key}.\n", 0}
    assert_receive {:turn, [{:user, "From shell:ops:\nhello there"}]}
  end

  test "ask follows the answer live, and says so where it cannot" do
    {key, _agent} =
      Wardrik.Test.Fleet.start_agent(
        config: Script.new({AgentRunners, :emitting, ["# Shipped\nall done\n"]})
      )

    assert command(["ask", key, "ship it"]) == {"", :live}
    assert live(["ask", key, "ship", "it"]) == {"Shipped\nall done\n", 0}
  end

  test "ask that parks says what it waits on and how to decide it; one that fails exits 1" do
    {parking, _agent} =
      Wardrik.Test.Fleet.start_agent(
        config: Script.new({AgentRunners, :parking, [self(), "call_1"]})
      )

    {output, 0} = live(["ask", parking, "deploy"])
    assert output =~ "Waiting on a person for 1 call:\n  ? deploy  call_1"
    assert output =~ "wardrik approve #{parking}, or deny, decides it."

    {failing, _agent} =
      Wardrik.Test.Fleet.start_agent(
        config: Script.new({AgentRunners, :failing, [:rate_limited]})
      )

    assert live(["ask", failing, "hi"]) == {"✗ the turn failed: :rate_limited\n", 1}
    assert live(["ask", "nobody/here", "hi"]) == {"No agent runs under nobody/here.\n", 1}
  end

  # A live command in a process of its own, writing to a terminal that sends
  # the test each line and stops when told, as Ctrl-C ends the VM a live
  # command writes to.
  defp watching(args) do
    parent = self()
    args = ["--terminal=80,plain,no-input,user=ops" | Enum.map(args, &to_string/1)]
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

    Wardrik.Test.Events.emit(key, %Event.Result{text: "first\n"})

    Wardrik.Test.Events.emit(
      key,
      %Event.ToolStarted{
        call_id: "call_1",
        name: "deploy",
        arguments: %{},
        idempotency_key: "key",
        decided_by: %{by: :default, hooks: []}
      }
    )

    assert_receive {:written, "first\n"}
    assert_receive {:written, "  → deploy\n"}

    send(terminal, :close)
    assert_receive {:watched, :ok}
    assert command(["watch", key]) == {"", :live}
    assert live(["watch", "nobody/here"]) == {"No agent runs under nobody/here.\n", 1}
  end

  test "watch --json writes each event of the log as a line of JSON" do
    key = Wardrik.Test.Fleet.id()
    :ok = Wardrik.Event.Log.subscribe(key)
    {^key, _agent} = Wardrik.Test.Fleet.start_agent([], key)
    # Its start is in its log before anything watches it, so no late write
    # reaches a terminal that has closed.
    assert_receive %Wardrik.Event.Log.Entry{sequence: 1}
    resource = Wardrik.AgentID.resource(key)
    :ok = Group.monitor(Wardrik.Event.Log, key.org)
    terminal = watching(["watch", key, "--json"])
    assert_receive {:group, [%Group.Event{type: :joined, meta: %{^resource => :all}} | _], _info}

    # Whatever else the agent writes as it settles is a line of its own, so
    # the test waits for this one.
    event = %{"type" => "wardrik.message.delta", "data" => %{"delta" => "hi"}}
    line = JSON.encode!(event) <> "\n"
    Wardrik.Event.Log.publish(%Wardrik.Event.Log.Entry{log: key, event: event, follows: 0})
    assert_receive {:written, ^line}

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
             run(&CLI.live/1, ["--terminal=80,plain,no-input,user=ops", "approve", key], "")

    assert live(["approve", "nobody/here"]) == {"No agent runs under nobody/here.\n", 1}
  end

  test "history prints what has been said, and says when nothing has" do
    test_pid = self()

    {key, agent} =
      Wardrik.Test.Fleet.start_agent(
        config: Script.new({AgentRunners, :echo, [test_pid, "hello back"]})
      )

    assert command(["history", key]) == {"Nothing has been said yet.\n", 0}

    :ok = Event.Bus.subscribe(key)
    Agent.ask(agent, "hello", host: Host.host())
    assert_receive %Event{payload: %Event.TurnFinished{}}

    assert command(["history", key]) == {"user: hello\n\nassistant: hello back\n", 0}
  end

  test "clear empties what has been said" do
    {key, agent} =
      Wardrik.Test.Fleet.start_agent(
        config: Script.new({AgentRunners, :echo, [self(), "hello back"]})
      )

    :ok = Event.Bus.subscribe(key)
    Agent.ask(agent, "hello", host: Host.host())
    assert_receive %Event{payload: %Event.TurnFinished{}}

    assert command(["clear", key]) == {"Cleared #{key}'s conversation.\n", 0}
    assert command(["history", key]) == {"Nothing has been said yet.\n", 0}
    assert command(["clear", "nobody/here"]) == {"No agent runs under nobody/here.\n", 1}
    assert Audit.about(key) == [{"agent.cleared", @ops}]
    assert Audit.about("agents/nobody/here") == []
  end

  test "a KEY in the deployment's org may leave the org out, and one that is not a key is refused" do
    test_pid = self()
    name = "bare-#{System.unique_integer([:positive])}"

    {key, _agent} =
      Wardrik.Test.Fleet.start_agent(
        [config: Script.new({AgentRunners, :echo, [test_pid, "hi"]})],
        Wardrik.AgentID.new!(name, org: "default")
      )

    assert to_string(key) == "default/#{name}"
    assert command(["ask", name, "hello", "--no-wait"]) == {"Asked #{key}.\n", 0}
    assert_receive {:turn, [{:user, "From shell:ops:\nhello"}]}

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
    Host.start_agents(
      Path.join(System.tmp_dir!(), "wardrik-cli-#{System.unique_integer([:positive])}")
    )

    assert {status, 0} = command(["status"])
    assert status =~ "on #{node()}"
    assert {reloaded, 0} = command(["reload"])
    assert reloaded =~ "on #{node()}"
    assert {"agents.reloaded", @ops} in Audit.about("agents")
  end

  test "audit reads what people changed, a page at a time" do
    :ok =
      Wardrik.Audit.record(Wardrik.Audit, {:agents_reloaded, [node()]},
        by: Wardrik.Principal.new("acme/@ops")
      )

    last = String.to_integer(List.last(Audit.all())["sequence"])
    previous = to_string(last - 1)

    assert {page, 0} = command(["audit", "--after", previous, "--limit", "1"])
    assert [change, more, ""] = String.split(page, "\n")
    assert change =~ ~r/^#{last}  \S+  agents.reloaded  agents  by acme\/@ops$/
    assert more == "More: wardrik audit --after #{last}"

    assert {"No changes after #{last}.\n", 0} == command(["audit", "--after", to_string(last)])

    {output, 0} = command(["audit", "--after", previous, "--json"])
    assert %{"changes" => [%{"type" => "wardrik.agents.reloaded"}]} = JSON.decode!(output)

    assert {_usage, 1} = command(["audit", "--limit", "0"])
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
    Host.declare(["acme", org])
    on_exit(fn -> File.rm_rf!(dir) end)
    on_exit(fn -> Wardrik.Fleet.forget_under(Wardrik.Resource.parse!(org <> "/*")) end)
    File.mkdir_p!(Path.join(dir, "agents"))

    File.write!(Path.join([dir, "agents", "counter.md"]), """
    ---
    org: #{org}
    description: Counts what it is asked to.
    tools: [web_search]
    policy:
      budget:
        tokens: 500
    triggers:
      name: tally
      every: 30m
      prompt: Count again.
    ---
    You count.
    """)

    Host.start_agents(dir)
    key = Wardrik.AgentID.parse!("#{org}/counter")

    Wardrik.Test.Fleet.await_update(fn ->
      Wardrik.Fleet.lookup(key, host: Host.host()) != nil
    end)

    {output, 0} = command(["show", key])
    assert output =~ "╭─#{key}"
    assert output =~ "Counts what it is asked to."
    assert output =~ ~r"status +idle on #{node()}"
    assert output =~ ~r"tools +web_search"
    assert output =~ ~r"policy +the file's own: no rules; otherwise allow"
    assert output =~ ~r"budget +0 of 500 tokens today"
    assert output =~ ~r"trigger +every 30m +next in \d+m +not run yet"
    assert output =~ Path.join([dir, "agents", "counter.md"])

    thread = Wardrik.AgentID.put_external_id(key, "1696.1234")
    {:ok, spec} = WardrikDaemon.Agents.spec(Host.agents(), thread, host: Host.host())
    {:ok, _pid} = Wardrik.Fleet.spawn(thread, Wardrik.Agent.Spec.options(spec))
    {output, 0} = command(["show", thread])
    assert output =~ "Counts what it is asked to."
    assert output =~ ~r"conversation +of #{key}"
    assert output =~ ~r"tools +web_search"

    defined = Wardrik.AgentID.parse!("#{org}/defined")

    token = %Wardrik.Token{
      principal: Wardrik.Principal.new("acme/@jon"),
      scope: [Wardrik.Role.bind([:owner], [Wardrik.AgentID.resource(defined)])]
    }

    {:ok, spec} =
      Host.define(defined, %{"description" => "Defined."}, {:api, token})

    {:ok, _pid} = Wardrik.Fleet.put(spec)
    {output, 0} = command(["show", defined])
    assert output =~ "Defined."
    assert output =~ ~r"file +none; it was defined over the HTTP API"

    parked = parked_agent()
    {output, 0} = command(["show", parked])
    assert output =~ ~r"waiting +call_1 +deploy +This ships to production."
    assert output =~ ~r"definition +none kept; it was started without one"

    assert command(["show", "nobody/here"]) == {"No agent runs under nobody/here.\n", 1}
  end

  test "triggers lists each trigger's next run, and its last and what came of it" do
    org = "cli-#{System.unique_integer([:positive])}"
    pattern = org <> "/agent/*"
    key = Wardrik.AgentID.parse!(org <> "/pinger")
    on_exit(fn -> WardrikTrigger.sync(key, []) end)

    assert {output, 0} = command(["triggers", pattern])
    assert output == "No agent #{pattern} covers has a trigger.\n"

    :ok = Event.Bus.subscribe(key, level: :lifecycle)
    {:ok, _pid} = WardrikTrigger.put(key, "hourly", every: "0 * * * *", prompt: "Ping.")

    {:ok, _pid} =
      WardrikTrigger.put(key, "tick", every: %WardrikTrigger.Interval{ms: 50}, prompt: "Ping.")

    # A trigger announces a firing before it records it, so the second
    # firing is the first that finds the one before it written down.
    assert_receive %Event{payload: %Event.TriggerFired{name: "tick", outcome: :no_agent}}
    assert_receive %Event{payload: %Event.TriggerFired{name: "tick", outcome: :no_agent}}

    assert {output, 0} = command(["triggers", pattern])
    assert output =~ "2 triggers:"
    assert output =~ ~r"  #{key}/hourly  0 \* \* \* \* Etc/UTC  next in \d+[ms]  not run yet"

    assert output =~
             ~r"  #{key}/tick  every 50ms  next in \d+s  last run \d+s ago: no agent runs under the key"

    hook = WardrikTrigger.Webhook.new("issues", secret: "ISSUES_HOOK_SECRET", prompt: "Look.")
    {:ok, _pid} = WardrikTrigger.put(key, hook)
    assert {output, 0} = command(["triggers", pattern])

    assert output =~
             ~r"  #{key}/issues  on request  http://127\.0\.0\.1:\d+/v1/hooks/#{key}/issues  not run yet"
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

    here = to_string(node())

    {output, 0} = command(["status", "--json"])
    assert %{"nodes" => [%{"name" => ^here, "agents" => agents}]} = JSON.decode!(output)
    assert agents >= 1

    {output, 0} = command(["history", key, "--json"])

    assert %{"agent" => %{"id" => ^key}, "interrupts" => [%{"id" => "call_1"}]} =
             JSON.decode!(output)

    {output, 0} = command(["parked", "--json"])
    assert %{"interrupts" => interrupts} = JSON.decode!(output)

    assert %{"id" => "call_1", "reason" => "tool_approval", "agent" => %{"id" => ^key}} =
             Enum.find(interrupts, &(&1["agent"]["id"] == key))
  end

  test "--json answers a failure as the HTTP API's error document" do
    {output, 1} = command(["history", "nobody/here", "--json"])

    assert JSON.decode!(output) == %{
             "error" => %{"type" => "not_found", "message" => "No agent runs under nobody/here."}
           }

    {output, 1} = command(["history", "--json"])

    assert %{
             "error" => %{
               "type" => "invalid_request",
               "message" => "Usage: wardrik history KEY [--json]"
             }
           } =
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

      groups = CLI.commands() |> Enum.map(& &1.group) |> Enum.dedup()
      assert groups == Enum.uniq(groups)
      for group <- groups, do: assert(text =~ "#{group}:\n")
      assert text =~ "Usage: wardrik [--node NAME] COMMAND"
      assert text =~ "rik ls is wardrik ls"
      assert text =~ WardrikDaemon.Config.config_dir()
      assert unanswered([]) == {:ok, text}
    end

    test "help for a command gives it in full, and for a group lists it" do
      {:ok, text} = unanswered(["help", "token", "create", "--help"])
      assert text =~ "Usage: wardrik token create NAME --resource PATTERN..."
      assert text =~ "--role ROLES is what it may do there"

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
