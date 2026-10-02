defmodule WardrikDaemon.CLI.LifecycleTest do
  use ExUnit.Case, async: false
  use Mimic

  import ExUnit.CaptureIO

  alias Wardrik.Agent
  alias Wardrik.Event
  alias Wardrik.Fleet
  alias Wardrik.Test.AgentRunners
  alias WardrikConsole.Nodes
  alias WardrikDaemon.CLI

  @moduletag :tmp_dir
  @defaults %{"model" => "anthropic:claude-sonnet-5", "tools" => ["web_search"]}
  @prompt "You are a helpful assistant. Answer briefly, and say what you do not know.\n"

  setup %{tmp_dir: dir} do
    previous = Application.get_env(:wardrik, WardrikDaemon.Agents)
    Application.put_env(:wardrik, WardrikDaemon.Agents, defaults: @defaults)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:wardrik, WardrikDaemon.Agents, previous),
        else: Application.delete_env(:wardrik, WardrikDaemon.Agents)
    end)

    start_supervised!({WardrikDaemon.Agents, dir: dir})
    org = "life-#{System.unique_integer([:positive])}"
    on_exit(fn -> Fleet.forget_under(org <> "/") end)

    %{dir: dir, org: org, here: Nodes.display(node())}
  end

  # Runs a command as over erl_call, answering what it printed and how it
  # exited: 0, 1, or :live for one that needs the terminal it came from.
  defp command(args), do: run(&CLI.main/1, args, "")

  # Runs a command live, as over bin/wardrikd rpc, from a terminal someone can
  # type `input` into, or, with `input?: false`, one nobody can.
  defp live(args, input \\ "", opts \\ []) do
    terminal =
      if Keyword.get(opts, :input?, true),
        do: "--terminal=80,plain,input",
        else: "--terminal=80,plain,no-input"

    run(&CLI.live/1, [terminal | args], input)
  end

  defp run(entry, args, input) do
    parent = self()

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

  defp agent(org, name, opts \\ []) do
    {key, _pid} = Wardrik.Test.Fleet.start_agent(opts, "#{org}/#{name}")
    key
  end

  defp parked(org, name) do
    key = agent(org, name, runner: {AgentRunners, :parking, [self(), "call_1"]})
    :ok = Event.Bus.subscribe(key)
    :ok = Agent.ask(key, "ship it")
    assert_receive %Event{payload: {:turn_parked, _calls}}
    assert Wardrik.Test.Fleet.await_update(fn -> status(key) == :parked end)
    key
  end

  defp status(key) do
    case Fleet.lookup(key) do
      nil -> nil
      member -> member.status
    end
  end

  describe "spawn" do
    test "writes the agent's file from the defaults, and starts it", context do
      %{dir: dir, org: org, here: here} = context
      key = "#{org}/helper"

      assert command(["agent", "spawn", "helper", "--org", org]) ==
               {"Wrote agents/helper.md, and started #{key} on #{here}, with " <>
                  "anthropic:claude-sonnet-5.\nwardrik agent edit #{key} changes what it is for.\n",
                0}

      assert File.read!(Path.join(dir, "agents/helper.md")) ==
               "---\norg: #{org}\nmodel: anthropic:claude-sonnet-5\ntools: [\"web_search\"]\n---\n" <>
                 @prompt

      assert status(key) == :idle
      assert [{_path, {:ok, _spec}}] = WardrikDaemon.Agents.files()

      assert command(["agent", "spawn", "helper", "--org", org]) ==
               {"#{key} runs already, on #{here}.\n", 0}
    end

    test "puts an agent with a user, on the node named", %{dir: dir, org: org, here: here} do
      key = "#{org}/@jon/digest"

      {output, 0} =
        command(["agent", "spawn", "digest", "--org", org, "--user", "jon", "--on", here])

      assert output =~ "Wrote agents/digest.md, and started #{key} on #{here}"
      assert File.read!(Path.join(dir, "agents/digest.md")) =~ "---\norg: #{org}\nuser: jon\n"
      assert Fleet.lookup(key).node == node()

      assert command(["agent", "spawn", "other", "--on", "nowhere"]) ==
               {"No node nowhere runs wardrik; the nodes are #{here}.\n", 1}
    end

    test "refuses a name that is not one", %{org: org} do
      rule = ": a name holds no / or whitespace, and does not begin with @ or _\n"

      assert command(["agent", "spawn", "a/b"]) == {"a/b is not an agent's name" <> rule, 1}

      assert command(["agent", "spawn", "a", "--org", "@x"]) ==
               {"--org @x is not an org's name" <> rule, 1}

      assert command(["agent", "spawn", "a", "--org", org, "--user", "_x"]) ==
               {"--user _x is not a user's name" <> rule, 1}
    end

    test "starts a stopped agent again, as its file declares it or as it was", context do
      %{dir: dir, org: org, here: here} = context
      {_output, 0} = command(["agent", "spawn", "helper", "--org", org])
      key = "#{org}/helper"

      assert command(["agent", "stop", key]) ==
               {"Stopped #{key}, and kept its conversation. agents/helper.md declares it, so " <>
                  "wardrik reload, or wardrik agent spawn helper --org #{org}, starts it again.\n",
                0}

      assert status(key) == nil

      assert command(["agent", "spawn", "helper", "--org", org]) ==
               {"Started #{key} on #{here}, as agents/helper.md declares it.\n", 0}

      loose = agent(org, "loose", runner: {AgentRunners, :echo, [self(), "hello back"]})
      :ok = Agent.ask(loose, "hello")
      assert_receive {:turn, [{:user, "hello"}]}
      assert Wardrik.Test.Fleet.await_update(fn -> status(loose) == :idle end)

      assert command(["agent", "stop", loose]) ==
               {"Stopped #{loose}, and kept its conversation. wardrik agent spawn loose " <>
                  "--org #{org} starts it again.\n", 0}

      assert command(["agent", "spawn", "loose", "--org", org]) ==
               {"Started #{loose} on #{here} again, with its conversation.\n", 0}

      refute File.exists?(Path.join(dir, "agents/loose.md"))
      assert [_hello, _back] = loose |> Agent.get_context() |> ReqLLM.Context.to_list()

      assert command(["agent", "stop", "nobody/here"]) ==
               {"No agent runs under nobody/here.\n", 1}
    end

    test "keeps a file that is there, and writes none the defaults make no agent of", context do
      %{dir: dir, org: org} = context
      File.mkdir_p!(Path.join(dir, "agents"))

      File.write!(
        Path.join(dir, "agents/other.md"),
        "---\nname: different\norg: #{org}\n---\nHi.\n"
      )

      File.write!(Path.join(dir, "agents/broken.md"), "---\ntools: nope\n---\nHi.\n")
      {_status, 0} = command(["reload"])

      assert command(["agent", "spawn", "other", "--org", org]) ==
               {"agents/other.md is there already, and declares #{org}/different.\n", 1}

      assert command(["agent", "spawn", "broken"]) ==
               {"agents/broken.md is there already, and is kept as it is: wardrik reload " <>
                  "reads it, and wardrik status says why where it does not.\n", 1}

      Application.put_env(:wardrik, WardrikDaemon.Agents, defaults: %{"tools" => "web_search"})

      assert command(["agent", "spawn", "fresh", "--org", org]) ==
               {"config.yaml's defaults do not make an agent for #{org}/fresh: tools is a list\n",
                1}

      refute File.exists?(Path.join(dir, "agents/fresh.md"))
    end
  end

  describe "cancel" do
    test "ends the turn an agent is taking, or every turn under a prefix", %{org: org} do
      key = parked(org, "parker")

      assert command(["agent", "cancel", key]) ==
               {"Abandoned the calls #{key} waited on, and the messages waiting behind " <>
                  "them. It keeps running, with what was said so far.\n", 0}

      assert Wardrik.Test.Fleet.await_update(fn -> status(key) == :idle end)

      assert command(["agent", "cancel", key]) ==
               {"#{key} is taking no turn, so there is none to cancel.\n", 0}

      assert command(["agent", "cancel", org <> "/"]) ==
               {"No agent under #{org}/ is taking a turn.\n", 0}

      :ok = Agent.ask(key, "ship it again")
      assert_receive %Event{payload: {:turn_parked, _calls}}
      assert Wardrik.Test.Fleet.await_update(fn -> status(key) == :parked end)

      assert command(["agent", "cancel", org <> "/"]) ==
               {"Cancelled the turns of #{key}. They keep running.\n", 0}

      assert command(["agent", "cancel", "nobody/"]) == {"Nothing runs under nobody/.\n", 0}

      assert command(["agent", "cancel", "nobody/here"]) ==
               {"No agent runs under nobody/here.\n", 1}

      assert command(["agent", "cancel", ""]) ==
               {"Name an agent's key, or a prefix such as acme/.\n", 1}
    end
  end

  describe "cancel --all" do
    test "ends the turn of every agent there is, and takes no key beside it", %{org: org} do
      key = parked(org, "anyone")

      assert {"Cancelled the turns of " <> _keys, 0} = command(["agent", "cancel", "--all"])
      assert Wardrik.Test.Fleet.await_update(fn -> status(key) == :idle end)

      assert {"No agent is taking a turn.\n", 0} = command(["agent", "cancel", "--all"])
      assert {_usage, 1} = command(["agent", "cancel"])
      assert {_usage, 1} = command(["agent", "cancel", key, "--all"])
    end
  end

  describe "rm" do
    test "lists what it removes and asks first", %{org: org} do
      first = agent(org, "first")
      second = agent(org, "second")

      assert command(["agent", "rm", org <> "/"]) == {"", :live}

      {output, 0} = live(["agent", "rm", org <> "/"], "n\n")

      assert output =~
               "This removes 2 agents, their conversations and their schedules, for good:\n" <>
                 "  #{first}\n  #{second}\n"

      assert output =~ "Remove them?"
      assert output =~ "Nothing was removed."
      assert status(first) == :idle

      {output, 0} = live(["agent", "rm", org <> "/"], "y\n")
      assert output =~ "Removed #{first} and #{second}."
      refute Fleet.stored?(first)
      refute Fleet.stored?(second)
    end

    test "needs --yes where nobody can answer, and removes a stopped agent", %{org: org} do
      key = agent(org, "lone")

      {output, 1} = live(["agent", "rm", key], "", input?: false)
      assert output =~ "This removes #{key}, its conversation and its schedules, for good."
      assert output =~ "wardrik agent rm #{key} --yes removes without asking."

      :ok = Fleet.stop(key)
      assert command(["agent", "rm", key, "--yes"]) == {"Removed #{key}.\n", 0}
      refute Fleet.stored?(key)

      assert command(["agent", "rm", key]) == {"No agent runs under #{key}.\n", 1}
      assert command(["agent", "rm", "nobody/"]) == {"Nothing runs under nobody/.\n", 1}
    end

    test "leaves an agent a file declares, and names the file", %{org: org} do
      {_output, 0} = command(["agent", "spawn", "helper", "--org", org])
      helper = "#{org}/helper"
      other = agent(org, "other")

      declared =
        "#{helper} is declared by agents/helper.md, and stays; remove agents/helper.md, then"

      assert command(["agent", "rm", helper, "--yes"]) ==
               {declared <> " wardrik reload removes it.\n", 1}

      assert command(["agent", "rm", org <> "/", "--yes"]) ==
               {"Removed #{other}.\n#{declared} wardrik reload removes it.\n", 0}

      assert status(helper) == :idle
    end

    test "leaves an agent a file on another node declares", %{dir: dir, org: org} do
      other = :"lifecycle-test@elsewhere"
      stop_supervised!(WardrikDaemon.Agents)
      start_supervised!({WardrikDaemon.Agents, dir: dir, nodes: fn -> [other] end})
      key = agent(org, "theirs")

      {:ok, _vsn} = Wardrik.Store.put(:declared, "agents/#{other}", %{key => "theirs.md"})
      on_exit(fn -> Wardrik.Store.delete(:declared, "agents/#{other}") end)

      assert command(["agent", "rm", key, "--yes"]) ==
               {"#{key} is declared by agents/theirs.md on #{other}; change the file\n", 1}

      assert status(key) == :idle
    end
  end

  describe "move" do
    setup do
      stub(CLI, :daemons, fn -> [node(), :wardrik_b@localhost] end)
      :ok
    end

    test "names the nodes where the one named is not there", %{org: org, here: here} do
      key = agent(org, "mover")

      assert command(["agent", "move", key, "nowhere"]) ==
               {"No node nowhere runs wardrik; the nodes are #{here} and b.\n", 1}

      assert command(["agent", "move", key, here]) == {"#{key} runs on #{here} already.\n", 0}

      assert command(["agent", "move", "nobody/here", "b"]) ==
               {"No agent runs under nobody/here.\n", 1}
    end

    test "moves an idle agent, and asks which node where none is named", %{org: org} do
      key = agent(org, "mover")
      expect(Fleet, :move, 2, fn ^key, :wardrik_b@localhost -> {:ok, self()} end)

      assert command(["agent", "move", key, "b"]) ==
               {"Moved #{key} to b, with its conversation.\n", 0}

      assert command(["agent", "move", key]) == {"", :live}

      {output, 0} = live(["agent", "move", key], "1\n")
      assert output =~ "Move #{key} from #{Nodes.display(node())} to which node?"
      assert output =~ "Moved #{key} to b, with its conversation."

      {output, 1} = live(["agent", "move", key], "", input?: false)

      assert output ==
               "wardrik agent move asks which node only where someone can answer; name it, as " <>
                 "in wardrik agent move #{key} b. The nodes are b.\n"
    end

    test "asks before it abandons a turn, unless told --yes", %{org: org} do
      key = parked(org, "parker")
      expect(Fleet, :move, 2, fn ^key, :wardrik_b@localhost -> {:ok, self()} end)
      waiting = "#{key} is waiting on a person, and moving it abandons what it waits for."

      assert command(["agent", "move", key, "b"]) == {"", :live}

      assert live(["agent", "move", key, "b"], "", input?: false) ==
               {waiting <> " wardrik agent move #{key} b --yes moves it anyway.\n", 1}

      {output, 0} = live(["agent", "move", key, "b"], "n\n")
      assert output =~ waiting
      assert output =~ "Nothing was moved."

      {output, 0} = live(["agent", "move", key, "b"], "y\n")
      assert output =~ "Moved #{key} to b"

      assert command(["agent", "move", key, "b", "--yes"]) ==
               {"Moved #{key} to b, with its conversation.\n", 0}
    end

    test "says a running turn ends, and why a move failed", %{org: org} do
      key = agent(org, "busy", runner: {AgentRunners, :blocking, [self(), "done"]})
      :ok = Agent.ask(key, "work")
      assert_receive {:turn, _messages, runner}
      assert Wardrik.Test.Fleet.await_update(fn -> status(key) == :running end)
      expect(Fleet, :move, fn ^key, :wardrik_b@localhost -> {:error, :no_capacity} end)

      {output, 1} = live(["agent", "move", key, "b"], "", input?: false)

      assert output =~
               "#{key} is taking a turn, which moving it ends; what it has said so far is kept."

      assert command(["agent", "move", key, "b", "--yes"]) ==
               {"#{key} was not moved: :no_capacity\n", 1}

      send(runner, :release)
    end

    test "says where there is nowhere to move to", %{org: org, here: here} do
      stub(CLI, :daemons, fn -> [node()] end)
      key = agent(org, "mover")

      assert live(["agent", "move", key]) ==
               {"#{here} is the only node, so there is nowhere to move #{key} to.\n", 1}
    end
  end

  describe "edit" do
    test "asks the node for the file that declares the agent", %{dir: dir, org: org} do
      {_output, 0} = command(["agent", "spawn", "helper", "--org", org])
      loose = agent(org, "loose")

      assert command(["__agent_file", "#{org}/helper"]) ==
               {Path.join(dir, "agents/helper.md") <> "\n", 0}

      assert command(["__agent_file", loose]) ==
               {"No file declares #{loose}: it was defined over the HTTP API, or started in " <>
                  "the TUI, so there is none to edit.\n", 1}

      assert command(["__agent_file", "nobody/here"]) == {"No agent runs under nobody/here.\n", 1}
      assert command(["__agent_file"]) == {"Usage: wardrik agent edit KEY\n", 1}

      assert command(["agent", "edit", loose]) ==
               {"bin/wardrik runs wardrik agent edit itself\n", 1}
    end
  end
end
