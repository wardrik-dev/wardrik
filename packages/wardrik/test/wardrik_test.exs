defmodule WardrikTest do
  use ExUnit.Case, async: false

  import Wardrik.Test.Wardrik

  setup :start_wardrik

  test "runs agents that write their events to it", %{wardrik: wardrik} do
    {:ok, agent} =
      Wardrik.start_agent(wardrik, agent_id: "acme/triage", model: "anthropic:claude-haiku-4-5")

    agents = Wardrik.agents(wardrik)
    assert WardrikCore.whereis(agents, "acme/triage") == agent
    assert WardrikCore.list(agents) == [{"acme/triage", nil}]

    events = Wardrik.events(wardrik)

    assert {:ok, %{events: [%{"type" => "wardrik.agent.started"}]}} =
             Wardrik.EventLog.page(events, ["acme/triage"])
  end

  test "makes a scope of who acts, for whom", %{wardrik: wardrik} do
    name = wardrik.name

    assert %Wardrik.Scope{
             wardrik: ^name,
             principal: %{id: "acme/@maria"},
             actor: nil,
             context: %{}
           } = Wardrik.as(wardrik, maria())

    assert %Wardrik.Scope{
             principal: %{id: "acme/@maria"},
             actor: {:agent, "acme/@maria/notes"},
             context: %{asked_by: "acme/@maria"}
           } =
             Wardrik.as(name, "acme/@maria",
               actor: {:agent, "acme/@maria/notes"},
               context: %{asked_by: "acme/@maria"}
             )

    assert_raise ArgumentError, fn -> Wardrik.as(name, "acme/@maria", roles: [:owner]) end

    assert_raise ArgumentError, ~r/^Elsewhere.Wardrik isn't started/, fn ->
      Wardrik.Instance.fetch!(Elsewhere.Wardrik)
    end

    assert %Wardrik.Scope{principal: %Wardrik.Principal{id: "acme/@jon"}} =
             Wardrik.as(wardrik, "acme/@jon")
  end

  test "won't start without an authorizer, or without a resolver" do
    resolver = [resolver: {Wardrik.Test.Owned, MyApp.AgentRuntime}]
    authorizer = [authorizer: {Wardrik.Test.Allow, []}]

    assert_raise NimbleOptions.ValidationError, ~r/required :authorizer option not found/, fn ->
      Wardrik.new([name: MyApp.AgentRuntime] ++ resolver)
    end

    assert_raise NimbleOptions.ValidationError, ~r/required :authorizer option not found/, fn ->
      Wardrik.start_link([name: MyApp.AgentRuntime] ++ resolver)
    end

    assert_raise NimbleOptions.ValidationError, ~r/required :resolver option not found/, fn ->
      Wardrik.new([name: MyApp.AgentRuntime] ++ authorizer)
    end

    assert_raise NimbleOptions.ValidationError, ~r/required :resolver option not found/, fn ->
      Wardrik.start_link([name: MyApp.AgentRuntime] ++ authorizer)
    end

    assert {:error, %NimbleOptions.ValidationError{key: :authorizer}} =
             NimbleOptions.validate([name: MyApp.AgentRuntime] ++ resolver, Wardrik.schema())

    assert {:error, %NimbleOptions.ValidationError{key: :resolver}} =
             NimbleOptions.validate([name: MyApp.AgentRuntime] ++ authorizer, Wardrik.schema())
  end

  test "has no tokens, and no operation of them" do
    refute Enum.any?(WardrikProtocol.operations(), &String.starts_with?(&1.id, "tokens."))
    refute Map.has_key?(Wardrik.Catalog.new().handlers, "tokens.create")
    refute function_exported?(Wardrik, :authenticate, 2)
    refute function_exported?(Wardrik, :grant, 2)
  end

  test "describes itself, with its agents kept in its store unless told otherwise" do
    store = Wardrik.Store.ETS.new(name: MyApp.Store)

    wardrik =
      Wardrik.new(
        authorizer: {Wardrik.Test.Allow, []},
        resolver: {Wardrik.Test.Owned, MyApp.AgentRuntime},
        name: MyApp.AgentRuntime,
        store: store
      )

    assert %Wardrik{
             deployment: "local",
             retention: 30,
             authorizer: {Wardrik.Test.Allow, []},
             resolver: {Wardrik.Test.Owned, MyApp.AgentRuntime},
             backend: {Wardrik.Store.Durable, store: ^store}
           } = wardrik

    assert Wardrik.agents(wardrik) == MyApp.AgentRuntime.Agents
    assert Wardrik.events(wardrik) == MyApp.AgentRuntime.Events
  end

  test "gives the options it takes, so a host can check them before it starts" do
    assert {:error, %NimbleOptions.ValidationError{key: :idle_timeout}} =
             NimbleOptions.validate(
               [
                 name: MyApp.AgentRuntime,
                 authorizer: {Wardrik.Test.Allow, []},
                 resolver: {Wardrik.Test.Owned, MyApp.AgentRuntime},
                 idle_timeout: "yes"
               ],
               Wardrik.schema()
             )
  end
end
