defmodule TarsTUI.App.FleetTest do
  use ExUnit.Case, async: false

  alias Tars.Agent
  alias Tars.Event
  alias Tars.Event.Bus
  alias Tars.Fleet
  alias Tars.Test.AgentRunners
  alias TarsTUI.App

  setup do
    org = "tui#{System.unique_integer([:positive])}"
    spawn_opts = [org: org, runner: {AgentRunners, :echo, [self(), "ok"]}]
    agent_id = Fleet.key("watched", spawn_opts)
    {:ok, _pid} = Fleet.spawn(agent_id, spawn_opts)
    on_exit(fn -> Fleet.forget(agent_id) end)

    session =
      Breeze.Test.start!(App,
        size: {90, 14},
        start_opts: [
          agent: agent_id,
          agent_id: agent_id,
          spawn_opts: spawn_opts,
          model: "test:model"
        ],
        global_keybindings: App.keybindings()
      )

    on_exit(fn -> Breeze.Test.stop(session) end)
    Breeze.Test.render_text!(session)

    {:ok, session: session, org: org, agent_id: agent_id}
  end

  defp screen(session), do: Breeze.Test.render_text!(session)

  defp submit(session, text) do
    Enum.each(String.graphemes(text), &Breeze.Test.input(session, &1))
    Breeze.Test.input(session, "Enter")
    session
  end

  test "the panel lists the agent this client is watching", %{session: session} do
    assert screen(session) =~ "fleet · 1"
    assert screen(session) =~ "› ○ watched"
  end

  test "ctrl-f focuses the panel, and from the panel puts it away", %{session: session} do
    ctrl_f(session)
    assert screen(session) =~ "fleet · 1"
    assert Breeze.Test.focused(session) == "fleet"

    ctrl_f(session)
    refute screen(session) =~ "fleet · 1"
    assert Breeze.Test.focused(session) == "prompt"

    ctrl_f(session)
    assert screen(session) =~ "fleet · 1"
  end

  test "arrows and enter in the panel connect to the chosen agent", ctx do
    %{session: session, org: org} = ctx
    other = spawn_and_ask(org, "other", "what is up")

    ctrl_f(session)
    # A frame between the focus and the keys, as there always is at a terminal.
    screen(session)
    Breeze.Test.input(session, "ArrowUp")
    Breeze.Test.input(session, "Enter")

    assert screen(session) =~ "connected to #{other}"
    assert screen(session) =~ "› what is up"
    assert Breeze.Test.focused(session) == "prompt"
  end

  test "the panel widens for long names and their node", %{session: session, org: org} do
    key = Fleet.key("assistant_with_a_long_name", org: org)
    on_exit(fn -> Fleet.forget(key) end)
    {:ok, _pid} = Fleet.spawn(key, runner: {AgentRunners, :echo, [self(), "ok"]})

    submit(session, "/fleet")

    assert screen(session) =~ "○ assistant_with_a_long_name"
  end

  @primary "38;5;4"

  test "the focused pane draws its edge in the primary colour", %{session: session} do
    for {focus, edge} <- [{"prompt", :prompt}, {"log", :transcript}, {"fleet", :fleet}] do
      Breeze.Test.focus(session, focus)
      edges = edges(session)

      assert edges[edge] == @primary, "#{focus} focused, but its edge is #{edges[edge]}"
      refute @primary in Map.values(Map.delete(edges, edge))
    end
  end

  test "tab cycles the prompt, the transcript and the panel, and nothing else", ctx do
    %{session: session} = ctx
    assert Breeze.Test.focused(session) == "prompt"

    focus_after_tabs =
      Enum.map(1..3, fn _tab ->
        Breeze.Test.input(session, "\t")
        screen(session)
        Breeze.Test.focused(session)
      end)

    assert focus_after_tabs == ["log", "fleet", "prompt"]
  end

  # The colour each pane's edge is drawn in: the prompt's top border, the
  # rule under the transcript, and the fleet panel's top border.
  defp edges(session) do
    lines = session |> Breeze.Test.render!() |> String.split("\n")
    [rule, _fleet_bottom] = lines |> Enum.find(&String.contains?(&1, "└")) |> String.split("└")
    [before_fleet, _rest] = lines |> Enum.find(&String.contains?(&1, "┌")) |> String.split("┌")

    %{
      prompt: lines |> Enum.find(&String.contains?(&1, "╭")) |> colours() |> List.first(),
      transcript: rule |> colours() |> List.first(),
      fleet: before_fleet |> colours() |> List.last()
    }
  end

  defp colours(line), do: ~r/38;5;\d+/ |> Regex.scan(line) |> List.flatten()

  defp ctrl_f(session), do: Breeze.Test.input(session, %{"key" => "f", "ctrlKey" => true})

  test "/spawn starts an agent beside this client's own and attaches to it", %{
    session: session,
    org: org
  } do
    key = "#{org}/_/helper"
    on_exit(fn -> Fleet.forget(key) end)

    submit(session, "/spawn helper")

    assert screen(session) =~ "spawned and connected to #{key}"
    assert Fleet.whereis(key)
  end

  test "/spawn sends the prompt as this client's first message", %{session: session, org: org} do
    on_exit(fn -> Fleet.forget("#{org}/_/asked") end)

    submit(session, "/spawn asked look into it")

    assert screen(session) =~ "› look into it"
    assert_receive {:turn, [{:user, "look into it"}]}
  end

  test "/connect moves this client onto another agent", %{session: session, org: org} do
    key = "#{org}/_/other"
    {:ok, _pid} = Fleet.spawn(key, runner: {AgentRunners, :echo, [self(), "ok"]})
    on_exit(fn -> Fleet.forget(key) end)

    submit(session, "/connect other")

    assert screen(session) =~ "connected to"
    assert screen(session) =~ "› ○ other"
  end

  test "/connect starts the transcript over with that agent's conversation", ctx do
    %{session: session, org: org} = ctx
    other = spawn_and_ask(org, "other", "what is up")
    submit(session, "hello from here")
    assert screen(session) =~ "hello from here"

    submit(session, "/connect other")

    refute screen(session) =~ "hello from here"
    assert screen(session) =~ "› what is up"
    assert screen(session) =~ "⏺ the answer"
    assert Fleet.whereis(other)
  end

  test "attaching on start shows the conversation so far", %{org: org} do
    key = spawn_and_ask(org, "resumed", "where were we")

    session =
      Breeze.Test.start!(App,
        size: {90, 14},
        start_opts: [agent: key, agent_id: key, model: "test:model"],
        global_keybindings: App.keybindings()
      )

    on_exit(fn -> Breeze.Test.stop(session) end)

    assert screen(session) =~ "› where were we"
    assert screen(session) =~ "⏺ the answer"
  end

  test "/spawn places the agent on the node it is given", %{session: session, org: org} do
    key = "#{org}/_/placed"
    on_exit(fn -> Fleet.forget(key) end)
    [short | _host] = node() |> Atom.to_string() |> String.split("@")

    submit(session, "/spawn placed node=#{short}")

    assert screen(session) =~ "spawned and connected to #{key}"
    assert Fleet.whereis(key)
  end

  test "/spawn says so when the node is not there", %{session: session} do
    submit(session, "/spawn nowhere node=elsewhere")

    assert screen(session) =~ ~s(no_such_node, "elsewhere")
  end

  test "/spawn refuses an option it does not know", %{session: session} do
    submit(session, "/spawn odd colour=red")

    assert screen(session) =~ ~s(unknown_options, ["colour"])
  end

  test "/move restarts an agent on the node it is given", ctx do
    %{session: session, agent_id: agent_id} = ctx
    before = Fleet.whereis(agent_id)
    [short | _host] = node() |> Atom.to_string() |> String.split("@")

    submit(session, "/move watched node=#{short}")

    assert screen(session) =~ "moved #{agent_id} to #{node()}"
    assert Fleet.whereis(agent_id) != before
    assert screen(session) =~ "› ○ watched"
  end

  test "/move needs a node", %{session: session} do
    submit(session, "/move watched")

    assert screen(session) =~ ":node_required"
  end

  # An agent under `org` that has already answered one question.
  defp spawn_and_ask(org, name, question) do
    key = Fleet.key(name, org: org)
    runner = {AgentRunners, :echo, [self(), "the answer"]}
    {:ok, pid} = Fleet.spawn(key, runner: runner)
    on_exit(fn -> Fleet.forget(key) end)
    :ok = Bus.subscribe(key)

    Agent.ask(pid, question)
    assert_receive %Event{payload: {:turn_finished, _messages}}
    :ok = Bus.unsubscribe(key)

    key
  end

  test "/connect says so when nothing holds the key", %{session: session, org: org} do
    submit(session, "/connect nobody")

    assert screen(session) =~ "no agent at #{org}/_/nobody"
  end

  test "/fleet lists the agents in the transcript", %{session: session, agent_id: agent_id} do
    submit(session, "/fleet")

    assert screen(session) =~ agent_id
  end

  test "/kill NAME removes the agent and its store", %{session: session, org: org} do
    key = Fleet.key("doomed", org: org)
    {:ok, _pid} = Fleet.spawn(key, runner: {AgentRunners, :echo, [self(), "ok"]})
    on_exit(fn -> Fleet.forget(key) end)

    submit(session, "/kill doomed")

    assert screen(session) =~ "removed #{key} and its store"
    assert Fleet.whereis(key) == nil
    assert {:error, :not_found} = DurableServer.Supervisor.get_server_info(Fleet, key)
  end

  test "/kill never removes the agent this client is attached to", ctx do
    %{session: session, agent_id: agent_id, org: org} = ctx

    submit(session, "/kill watched")
    assert screen(session) =~ "you are attached to #{agent_id}"

    submit(session, "/kill #{org}/")
    assert screen(session) =~ "you are attached to #{agent_id}"
    assert Fleet.whereis(agent_id)
  end

  test "/kill PREFIX/ removes every running agent under it", %{session: session} do
    org = "doomed#{System.unique_integer([:positive])}"
    keys = for name <- ["one", "two"], do: Fleet.key(name, org: org)

    for key <- keys do
      {:ok, _pid} = Fleet.spawn(key, runner: {AgentRunners, :echo, [self(), "ok"]})
      on_exit(fn -> Fleet.forget(key) end)
    end

    submit(session, "/kill #{org}/")

    assert screen(session) =~ "removed 2 under #{org}/"
    assert Enum.all?(keys, &(Fleet.whereis(&1) == nil))
  end

  test "/kill NAME says so when nothing holds the key", %{session: session, org: org} do
    submit(session, "/kill nobody")

    assert screen(session) =~ "no agent at #{org}/_/nobody"
  end

  test "/help lists the commands", %{session: session} do
    submit(session, "/help")

    assert screen(session) =~ "/quit"
    assert screen(session) =~ "this list"
  end

  test "/kill says so when a prefix matches nothing", %{session: session} do
    submit(session, "/kill nothing/here/")

    assert screen(session) =~ "nothing running under nothing/here/"
  end
end
