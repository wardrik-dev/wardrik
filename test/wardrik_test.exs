defmodule WardrikTest do
  use ExUnit.Case, async: false

  import Wardrik.Test.Wardrik

  setup :start_wardrik

  test "runs agents that write their events to it", %{wardrik: wardrik} do
    {:ok, agent} =
      Wardrik.start_agent(wardrik, agent_id: "acme/triage", model: "anthropic:claude-haiku-4-5")

    assert WardrikCore.whereis(Wardrik.agents(wardrik), "acme/triage") == agent
    assert WardrikCore.list(Wardrik.agents(wardrik)) == ["acme/triage"]

    assert {:ok, %{events: [%{"type" => "wardrik.agent.started"}]}} =
             WardrikEvents.page(Wardrik.events(wardrik), ["acme/triage"])
  end

  test "makes a scope of who acts, and what they're granted", %{wardrik: wardrik} do
    assert %Wardrik.Scope{wardrik: ^wardrik, principal: %{id: "acme/@maria"}, grants: [:all]} =
             Wardrik.as(wardrik, maria(), [:all])

    assert %Wardrik.Scope{principal: %WardrikCore.Principal{id: "acme/@jon"}} =
             Wardrik.as(wardrik, "acme/@jon")
  end

  test "describes itself, with its agents kept in its store unless told otherwise" do
    wardrik = Wardrik.new(name: MyApp.Wardrik, store: :store)

    assert %Wardrik{
             deployment: "local",
             retention: 30,
             authorizer: {Wardrik.Statements, []},
             backend: {WardrikStore.Durable, store: :store}
           } = wardrik

    assert Wardrik.agents(wardrik) == MyApp.Wardrik.Agents
    assert Wardrik.events(wardrik) == MyApp.Wardrik.Events
  end
end
