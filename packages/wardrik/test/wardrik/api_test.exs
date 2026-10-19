defmodule Wardrik.APITest do
  use ExUnit.Case, async: false

  alias Wardrik.Agent.Message
  alias Wardrik.Agent.Snapshot
  alias Wardrik.AgentID
  alias Wardrik.Error
  alias Wardrik.Event.Log.Entry
  alias Wardrik.Fleet.Member
  alias Wardrik.Forgetting
  alias Wardrik.Moving
  alias Wardrik.Servers.Server
  alias Wardrik.Spawned
  alias Wardrik.Test.AgentRunners

  setup_all do
    wardrik =
      Wardrik.new(
        store: Wardrik.Test.store(),
        issuer: %Wardrik.OrgIssuer{org: "acme"},
        context: Wardrik.context([])
      )

    %{
      wardrik: wardrik,
      scope: Wardrik.as(wardrik, maria()),
      root: Wardrik.Scope.new(Wardrik.host(wardrik), Wardrik.Token.root(maria()))
    }
  end

  defp maria, do: Wardrik.Principal.new(:user, "maria")

  defp id(name), do: AgentID.new!("#{name}-#{System.unique_integer([:positive])}", org: "acme")

  # An agent that echoes, or parks on the call "call_1", run without a model,
  # and so without compacting its history, which reads the model catalog.
  defp start(runner) do
    config = Wardrik.LLM.Config.new(history: %Wardrik.History.All{})
    {id, _pid} = Wardrik.Test.Fleet.start_agent([runner: runner, config: config], id("agent"))
    id
  end

  defp parked(scope) do
    id =
      start({AgentRunners, :parking, [self(), "call_1"]})

    {:ok, _message} = Wardrik.agent_ask(scope, id, "ship it")
    assert_receive :asked, 5_000

    assert Wardrik.Test.Fleet.await_update(fn ->
             Wardrik.Fleet.lookup(id, host: Wardrik.Test.host()).status == :parked
           end)

    id
  end

  test "a scope reaches what its principal's token reaches, and nothing else", %{
    scope: scope
  } do
    assert {:error, %Error{type: :not_found}} =
             Wardrik.agent_read(scope, AgentID.new!("support", org: "globex"))

    assert {:error, %Error{type: :forbidden}} = Wardrik.deployment_nodes(scope)
  end

  test "an agent is defined, read, listed and forgotten", %{scope: scope} do
    agent = id("support")
    definition = %{"model" => "anthropic:claude-sonnet-5", "instructions" => "Be brief."}

    assert {:ok, %Snapshot{agent: ^agent}} = Wardrik.agent_define(scope, agent, definition)

    assert {:ok, %Wardrik.Definition.Read{fields: %{"instructions" => "Be brief."}}} =
             Wardrik.agent_definition_read(scope, agent)

    assert {:ok, %Snapshot{agent: ^agent}} = Wardrik.agent_read(scope, agent)
    assert {:ok, members} = Wardrik.agents_list(scope, Wardrik.AgentID.resource(agent))
    assert Enum.any?(members, &(&1.id == agent))

    assert {:ok, trigger} =
             Wardrik.agent_trigger_set(scope, agent, "sweep", %{
               "every" => "1h",
               "prompt" => "Look."
             })

    assert trigger["name"] == "sweep"
    assert {:ok, %{"name" => "sweep"}} = Wardrik.agent_trigger_remove(scope, agent, "sweep")
    assert :ok = Wardrik.agent_forget(scope, agent)
    assert {:error, %Error{type: :not_found}} = Wardrik.agent_read(scope, agent)
  end

  test "an agent asked answers in its log, which a stream and a page read", %{scope: scope} do
    agent = start({AgentRunners, :echo, [self(), "on its way"]})

    assert :ok = Wardrik.agent_subscribe(scope, agent)

    assert {:ok, %Message{text: "where is it?", sequence: sequence}} =
             Wardrik.agent_ask(scope, agent, "where is it?", id: "m1")

    assert_receive {:turn, _messages}, 5_000
    assert_receive %Entry{event: %{"type" => "wardrik.run.completed"}}, 5_000

    assert {:ok, stream} = Wardrik.agent_stream(scope, agent, after: sequence)
    assert [%Entry{sequence: first} | _rest] = Enum.take(stream, 2)
    assert first == sequence + 1

    assert {:ok, [%Entry{sequence: ^first}]} =
             Wardrik.agent_events(scope, agent, after: sequence, limit: 1)

    assert {:ok, %Snapshot{agent: ^agent}} = Wardrik.agent_clear(scope, agent)
  end

  test "a stream follows what the agent writes after what it read", %{scope: scope} do
    agent = start({AgentRunners, :echo, [self(), "done"]})
    {:ok, %Snapshot{sequence: sequence}} = Wardrik.agent_read(scope, agent)
    {:ok, stream} = Wardrik.agent_stream(scope, agent, after: sequence)
    test = self()

    task =
      Task.async(fn ->
        send(test, :following)
        Enum.find(stream, &(&1.event["type"] == "wardrik.run.completed"))
      end)

    assert_receive :following
    {:ok, _message} = Wardrik.agent_ask(scope, agent, "anything?")
    assert %Entry{} = Task.await(task, 5_000)
  end

  test "a call an agent waits on is approved or denied", %{scope: scope} do
    agent = parked(scope)

    assert {:ok, [{^agent, {%{id: "call_1"}, _prompt}}]} =
             Wardrik.agents_parked(scope, Wardrik.AgentID.resource(agent))

    assert {:error, %Error{type: :not_found}} =
             Wardrik.agent_authorization_read(scope, agent, "call_1")

    assert {:ok, %{"call_1" => {:approve, "Only staging."}}} =
             Wardrik.agent_approve(scope, agent, "call_1", note: "Only staging.")

    denied = parked(scope)

    assert {:ok, %{"call_1" => {:deny, "Not now."}}} =
             Wardrik.agent_deny(scope, denied, ["call_1"], reason: "Not now.")

    decided = parked(scope)

    assert {:ok, %{"call_1" => {:approve, "Fine."}}} =
             Wardrik.agent_decide(scope, decided, %{"call_1" => {:approve, "Fine."}})
  end

  test "an agent is stopped, spawned, cancelled and moved", %{scope: scope, root: root} do
    agent = start({AgentRunners, :echo, [self(), "ok"]})

    assert {:ok, %Member{id: ^agent, asleep: true}} = Wardrik.agent_stop(scope, agent)

    assert {:ok, %Spawned{member: %Member{id: ^agent, asleep: false}, from: :store}} =
             Wardrik.agent_spawn(scope, agent)

    assert :ok = Wardrik.agent_cancel(scope, agent)
    assert {:ok, []} = Wardrik.agents_cancel(scope, Wardrik.AgentID.resource(agent))

    assert {:ok, %Spawned{member: %Member{node: node}, from: :running}} =
             Wardrik.agent_spawn(root, agent, node: node())

    assert node == node()
    assert {:ok, %Moving{from: ^node, to: ^node}} = Wardrik.agent_move_preview(root, agent, node)
    assert {:ok, %Member{id: ^agent}} = Wardrik.agent_move(root, agent, node())
    assert {:ok, []} = Wardrik.agent_calls(scope, agent)

    assert {:ok, %Forgetting{agents: [^agent]}} =
             Wardrik.agents_forget_preview(scope, Wardrik.AgentID.resource(agent))

    assert {:ok, %{^agent => :forgotten}} =
             Wardrik.agents_forget(scope, Wardrik.AgentID.resource(agent))
  end

  test "what the host does not offer answers so", %{scope: scope, root: root} do
    owner = Wardrik.Resource.parse!("acme")
    agent = start({AgentRunners, :echo, [self(), "ok"]})

    server = %Server{
      name: "docs",
      url: "https://docs.example.com/mcp",
      auth: "secret",
      secret: "k"
    }

    request = %{headers: [], body: "{}"}

    for answer <- [
          Wardrik.servers_list(scope, owner),
          Wardrik.servers_add(scope, owner, server),
          Wardrik.servers_remove(scope, owner, "docs"),
          Wardrik.connections_list(scope, owner),
          Wardrik.connections_connect(scope, owner, "github"),
          Wardrik.connections_disconnect(scope, owner, "github"),
          Wardrik.agent_trigger_deliver(scope, agent, "hook", request),
          Wardrik.tokens_list(root),
          Wardrik.tokens_create(root, "ci", root.token.scope),
          Wardrik.tokens_revoke(root, "t1")
        ],
        do: assert({:error, %Error{type: :unsupported}} = answer)
  end

  test "the deployment answers a scope over every agent", %{root: root} do
    assert {:ok, %Wardrik.Deployment.Nodes{nodes: [{node, _count}]}} =
             Wardrik.deployment_nodes(root)

    assert node == node()
    assert {:ok, [^node]} = Wardrik.deployment_reload(root)
    assert {:ok, changes} = Wardrik.deployment_audit(root, limit: 10)
    assert is_list(changes)
  end

  test "each function's ! variant answers the value, or raises the error",
       %{scope: scope, root: root} do
    owner = Wardrik.Resource.parse!("acme")
    agent = id("bang")
    definition = %{"model" => "anthropic:claude-sonnet-5"}

    assert %Snapshot{} = Wardrik.agent_define!(scope, agent, definition)
    assert %Wardrik.Definition.Read{} = Wardrik.agent_definition_read!(scope, agent)
    assert %Snapshot{} = Wardrik.agent_read!(scope, agent)
    assert [_ | _] = Wardrik.agents_list!(scope, Wardrik.AgentID.resource(agent))
    assert [] = Wardrik.agents_parked!(scope, Wardrik.AgentID.resource(agent))
    assert :ok = Wardrik.agent_subscribe!(scope, agent)
    assert Enumerable.impl_for(Wardrik.agent_stream!(scope, agent))
    assert [_ | _] = Wardrik.agent_events!(scope, agent)

    assert %{"name" => "s"} =
             Wardrik.agent_trigger_set!(scope, agent, "s", %{
               "every" => "1h",
               "prompt" => "Look."
             })

    assert %{"name" => "s"} = Wardrik.agent_trigger_remove!(scope, agent, "s")
    assert %Snapshot{} = Wardrik.agent_clear!(scope, agent)
    assert :ok = Wardrik.agent_cancel!(scope, agent)
    assert [] = Wardrik.agents_cancel!(scope, Wardrik.AgentID.resource(agent))
    assert %Member{asleep: true} = Wardrik.agent_stop!(scope, agent)
    assert %Spawned{} = Wardrik.agent_spawn!(scope, agent)
    assert %Moving{} = Wardrik.agent_move_preview!(root, agent, node())
    assert %Member{} = Wardrik.agent_move!(root, agent, node())
    assert [] = Wardrik.agent_calls!(scope, agent)
    assert %Forgetting{} = Wardrik.agent_forget_preview!(scope, agent)
    assert %Forgetting{} = Wardrik.agents_forget_preview!(scope, Wardrik.AgentID.resource(agent))
    assert %Wardrik.Deployment.Nodes{} = Wardrik.deployment_nodes!(root)
    assert is_list(Wardrik.deployment_audit!(root))
    assert [_node] = Wardrik.deployment_reload!(root)
    assert :ok = Wardrik.agent_forget!(scope, agent)

    parked = parked(scope)
    assert %{"call_1" => :approve} = Wardrik.agent_approve!(scope, parked, "call_1")
    denied = parked(scope)
    assert %{"call_1" => {:deny, _reason}} = Wardrik.agent_deny!(scope, denied, "call_1")
    decided = parked(scope)

    assert %{"call_1" => :approve} =
             Wardrik.agent_decide!(scope, decided, %{"call_1" => :approve})

    echo = start({AgentRunners, :echo, [self(), "ok"]})
    assert %Message{} = Wardrik.agent_ask!(scope, echo, "hi")
    assert %{^echo => :forgotten} = Wardrik.agents_forget!(scope, Wardrik.AgentID.resource(echo))

    for raising <- [
          fn -> Wardrik.agent_authorization_read!(scope, echo, "call_1") end,
          fn -> Wardrik.agent_call_kill!(scope, echo, "call_1") end,
          fn -> Wardrik.servers_list!(scope, owner) end,
          fn ->
            Wardrik.servers_add!(scope, owner, %Server{name: "d", url: "u", auth: "none"})
          end,
          fn -> Wardrik.servers_remove!(scope, owner, "d") end,
          fn -> Wardrik.connections_list!(scope, owner) end,
          fn -> Wardrik.connections_connect!(scope, owner, "github") end,
          fn -> Wardrik.connections_disconnect!(scope, owner, "github") end,
          fn -> Wardrik.agent_trigger_deliver!(scope, echo, "h", %{headers: [], body: ""}) end,
          fn -> Wardrik.tokens_list!(root) end,
          fn -> Wardrik.tokens_create!(root, "ci", root.token.scope) end,
          fn -> Wardrik.tokens_revoke!(root, "t1") end
        ],
        do: assert_raise(Error, raising)
  end
end
