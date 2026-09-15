defmodule TarsTUI.App.FleetTest do
  use ExUnit.Case, async: false

  alias Tars.Fleet
  alias TarsTUI.App

  setup do
    org = "tui#{System.unique_integer([:positive])}"
    agent_id = Fleet.key("watched", org: org)
    {:ok, _pid} = Fleet.spawn(agent_id, runner: {Tars.Test.AgentRunners, :echo, [self(), "ok"]})
    on_exit(fn -> Fleet.forget(agent_id) end)

    session =
      Breeze.Test.start!(App,
        size: {90, 14},
        start_opts: [agent: agent_id, agent_id: agent_id, model: "test:model"],
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

  test "/spawn starts an agent and says so", %{session: session, org: org} do
    key = "#{org}/_/helper"
    on_exit(fn -> Fleet.forget(key) end)

    submit(session, "/spawn #{key}")

    assert screen(session) =~ "spawned #{key}"
    assert Fleet.whereis(key)
  end

  test "/spawn passes a prompt straight to the new agent", %{session: session, org: org} do
    key = "#{org}/_/asked"
    on_exit(fn -> Fleet.forget(key) end)

    submit(session, "/spawn #{key} look into it")

    assert screen(session) =~ "asked look into it"
  end

  test "/connect moves this client onto another agent", %{session: session, org: org} do
    key = "#{org}/_/other"
    {:ok, _pid} = Fleet.spawn(key, runner: {Tars.Test.AgentRunners, :echo, [self(), "ok"]})
    on_exit(fn -> Fleet.forget(key) end)

    submit(session, "/connect #{key}")

    assert screen(session) =~ "connected to"
    assert screen(session) =~ "› ○ other"
  end

  test "/connect says so when nothing holds the key", %{session: session} do
    submit(session, "/connect no/such/agent")

    assert screen(session) =~ "no agent at no/such/agent"
  end

  test "/fleet lists the agents in the transcript", %{session: session, agent_id: agent_id} do
    submit(session, "/fleet")

    assert screen(session) =~ agent_id
  end

  test "/kill reports how many it reached", %{session: session, org: org} do
    submit(session, "/kill #{org}/")

    assert screen(session) =~ "stopped 1 under #{org}/"
  end

  test "/kill says so when a prefix matches nothing", %{session: session} do
    submit(session, "/kill nothing/here/")

    assert screen(session) =~ "nothing running under nothing/here/"
  end
end
