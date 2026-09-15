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

  test "ctrl-f puts the panel away and brings it back", %{session: session} do
    Breeze.Test.input(session, %{"key" => "f", "ctrlKey" => true})
    refute screen(session) =~ "fleet · 1"

    Breeze.Test.input(session, %{"key" => "f", "ctrlKey" => true})
    assert screen(session) =~ "fleet · 1"
  end

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

  test "/kill reports how many it reached", %{session: session, org: org} do
    submit(session, "/kill #{org}/")

    assert screen(session) =~ "stopped 1 under #{org}/"
  end

  test "/kill NAME interrupts one agent under this client's org", ctx do
    %{session: session, agent_id: agent_id} = ctx
    :ok = Bus.subscribe(agent_id)

    submit(session, "/kill watched")

    assert screen(session) =~ "interrupting #{agent_id}"
    assert_receive %Event{payload: {:turn_interrupted, _stats}}
  end

  test "/kill NAME says so when nothing holds the key", %{session: session, org: org} do
    submit(session, "/kill nobody")

    assert screen(session) =~ "no agent at #{org}/_/nobody"
  end

  test "/help lists the commands", %{session: session} do
    submit(session, "/help")

    assert screen(session) =~ "/fleet"
    assert screen(session) =~ "/approve · /deny [reason]"
  end

  test "/kill says so when a prefix matches nothing", %{session: session} do
    submit(session, "/kill nothing/here/")

    assert screen(session) =~ "nothing running under nothing/here/"
  end
end
