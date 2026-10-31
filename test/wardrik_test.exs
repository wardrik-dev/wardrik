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
    name = wardrik.name

    assert %Wardrik.Scope{wardrik: ^name, principal: %{id: "acme/@maria"}, grants: [:all]} =
             Wardrik.as(wardrik, maria(), [:all])

    assert %Wardrik.Scope{grants: [%Wardrik.Statement{actions: ["*"], resources: ["acme/*"]}]} =
             Wardrik.as(name, "acme/@maria", roles: [:owner], resources: ["acme/*"])

    assert %Wardrik.Scope{
             grants: [%Wardrik.Statement{}, %Wardrik.Statement{actions: ["agent.decide"]}]
           } =
             wardrik
             |> Wardrik.as("acme/@maria", roles: [:owner], resources: ["acme/*"])
             |> Wardrik.grant(roles: [:approver], resources: ["globex/*"])

    assert %Wardrik.Scope{grants: []} = Wardrik.as(name, "acme/@maria")

    assert_raise ArgumentError, ~r/^Elsewhere.Wardrik isn't started/, fn ->
      Wardrik.Instance.fetch!(Elsewhere.Wardrik)
    end

    assert %Wardrik.Scope{principal: %WardrikCore.Principal{id: "acme/@jon"}} =
             Wardrik.as(wardrik, "acme/@jon")
  end

  test "describes itself, with its agents kept in its store unless told otherwise" do
    store = WardrikStore.ETS.new(name: MyApp.Store)
    wardrik = Wardrik.new(name: MyApp.AgentRuntime, store: store)

    assert %Wardrik{
             deployment: "local",
             retention: 30,
             authorizer: {Wardrik.Statements, []},
             backend: {WardrikStore.Durable, store: ^store}
           } = wardrik

    assert Wardrik.agents(wardrik) == MyApp.AgentRuntime.Agents
    assert Wardrik.events(wardrik) == MyApp.AgentRuntime.Events
  end

  test "gives the options it takes, so a host can check them before it starts" do
    assert {:error, %NimbleOptions.ValidationError{key: :deployment_keys}} =
             NimbleOptions.validate(
               [name: MyApp.AgentRuntime, deployment_keys: "yes"],
               Wardrik.schema()
             )
  end
end
