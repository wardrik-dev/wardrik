defmodule Wardrik.APITest do
  use ExUnit.Case, async: false

  alias Wardrik.Agent.Message
  alias Wardrik.Agent.Snapshot
  alias Wardrik.AgentID
  alias Wardrik.AgentID.Prefix
  alias Wardrik.Error
  alias Wardrik.Event.Log.Entry
  alias Wardrik.Fleet.Member
  alias Wardrik.Servers.Server
  alias Wardrik.Test.AgentRunners

  setup_all do
    dir = Path.join(System.tmp_dir!(), "wardrik-api-#{System.unique_integer([:positive])}")

    wardrik =
      Wardrik.new(
        store: Wardrik.store(data_dir: dir),
        grants: %Wardrik.OrgGrants{org: "acme"},
        context: Wardrik.context([])
      )

    start_supervised!({Wardrik, wardrik})
    :ok = DurableServer.Supervisor.wait_until_ready(Wardrik.Fleet, timeout: 10_000)
    on_exit(fn -> File.rm_rf(dir) end)

    {:ok, root} = Wardrik.Grant.new(Prefix.all())

    %{
      wardrik: wardrik,
      session: Wardrik.as(wardrik, maria()),
      root: Wardrik.as(wardrik, maria(), grant: root)
    }
  end

  defp maria, do: Wardrik.Principal.new(:user, "maria")

  defp id(name), do: AgentID.new!("#{name}-#{System.unique_integer([:positive])}", org: "acme")

  # An agent that echoes, or parks on the call "call_1", run without a model.
  defp start(runner) do
    {id, _pid} = Wardrik.Test.Fleet.start_agent([runner: runner], id("agent"))
    id
  end

  defp parked(session) do
    id =
      start({AgentRunners, :parking, [self(), "call_1"]})

    {:ok, _message} = Wardrik.agent_ask(session, id, "ship it")
    assert_receive :asked, 5_000
    assert Wardrik.Test.Fleet.await_update(fn -> Wardrik.Fleet.lookup(id).status == :parked end)
    id
  end

  test "a session reaches what its principal's grants reach, and nothing else", %{
    session: session
  } do
    assert {:error, %Error{type: :not_found}} =
             Wardrik.agent_read(session, AgentID.new!("support", org: "globex"))

    assert {:error, %Error{type: :forbidden}} = Wardrik.deployment_nodes(session)
  end

  test "an agent is defined, read, listed and forgotten", %{session: session} do
    agent = id("support")
    definition = %{"model" => "anthropic:claude-sonnet-5", "instructions" => "Be brief."}

    assert {:ok, %Snapshot{agent: ^agent}} = Wardrik.agent_define(session, agent, definition)

    assert {:ok, %Wardrik.Definition.Read{fields: %{"instructions" => "Be brief."}}} =
             Wardrik.agent_definition_read(session, agent)

    assert {:ok, %Snapshot{agent: ^agent}} = Wardrik.agent_read(session, agent)
    assert {:ok, members} = Wardrik.agents_list(session, Prefix.of(agent))
    assert Enum.any?(members, &(&1.id == agent))

    assert {:ok, trigger} =
             Wardrik.agent_trigger_set(session, agent, "sweep", %{
               "every" => "1h",
               "prompt" => "Look."
             })

    assert trigger["name"] == "sweep"
    assert :ok = Wardrik.agent_trigger_remove(session, agent, "sweep")
    assert :ok = Wardrik.agent_forget(session, agent)
    assert {:error, %Error{type: :not_found}} = Wardrik.agent_read(session, agent)
  end

  test "an agent asked answers in its log, which a stream and a page read", %{session: session} do
    agent = start({AgentRunners, :echo, [self(), "on its way"]})

    assert :ok = Wardrik.agent_subscribe(session, agent)

    assert {:ok, %Message{text: "where is it?", sequence: sequence}} =
             Wardrik.agent_ask(session, agent, "where is it?", id: "m1")

    assert_receive {:turn, _messages}, 5_000
    assert_receive %Entry{event: %{"type" => "wardrik.run.completed"}}, 5_000

    assert {:ok, stream} = Wardrik.agent_stream(session, agent, after: sequence)
    assert [%Entry{sequence: first} | _rest] = Enum.take(stream, 2)
    assert first == sequence + 1

    assert {:ok, [%Entry{sequence: ^first}]} =
             Wardrik.agent_events(session, agent, after: sequence, limit: 1)

    assert :ok = Wardrik.agent_clear(session, agent)
  end

  test "a stream follows what the agent writes after what it read", %{session: session} do
    agent = start({AgentRunners, :echo, [self(), "done"]})
    {:ok, %Snapshot{sequence: sequence}} = Wardrik.agent_read(session, agent)
    {:ok, stream} = Wardrik.agent_stream(session, agent, after: sequence)
    test = self()

    task =
      Task.async(fn ->
        send(test, :following)
        Enum.find(stream, &(&1.event["type"] == "wardrik.run.completed"))
      end)

    assert_receive :following
    {:ok, _message} = Wardrik.agent_ask(session, agent, "anything?")
    assert %Entry{} = Task.await(task, 5_000)
  end

  test "a call an agent waits on is approved or denied", %{session: session} do
    agent = parked(session)

    assert {:ok, [{^agent, {%{id: "call_1"}, _prompt}}]} =
             Wardrik.agents_parked(session, Prefix.of(agent))

    assert {:error, %Error{type: :not_found}} =
             Wardrik.agent_authorization_read(session, agent, "call_1")

    assert {:ok, %{"call_1" => {:approve, "Only staging."}}} =
             Wardrik.agent_approve(session, agent, "call_1", note: "Only staging.")

    denied = parked(session)

    assert {:ok, %{"call_1" => {:deny, "Not now."}}} =
             Wardrik.agent_deny(session, denied, ["call_1"], reason: "Not now.")
  end

  test "an agent is stopped, spawned, cancelled and moved", %{session: session, root: root} do
    agent = start({AgentRunners, :echo, [self(), "ok"]})

    assert :ok = Wardrik.agent_stop(session, agent)
    assert {:ok, %Member{id: ^agent, asleep: false}} = Wardrik.agent_spawn(session, agent)
    assert :ok = Wardrik.agent_cancel(session, agent)
    assert {:ok, []} = Wardrik.agents_cancel(session, Prefix.of(agent))
    assert {:ok, %Member{node: node}} = Wardrik.agent_spawn(root, agent, node: node())
    assert node == node()
    assert {:ok, %Member{id: ^agent}} = Wardrik.agent_move(root, agent, node())
    assert {:ok, %{^agent => :forgotten}} = Wardrik.agents_forget(session, Prefix.of(agent))
  end

  test "what the host does not offer answers so", %{session: session, root: root} do
    owner = Prefix.new!(org: "acme")
    agent = start({AgentRunners, :echo, [self(), "ok"]})

    server = %Server{
      name: "docs",
      url: "https://docs.example.com/mcp",
      auth: "secret",
      secret: "k"
    }

    request = %{headers: [], body: "{}"}

    for answer <- [
          Wardrik.servers_list(session, owner),
          Wardrik.servers_add(session, owner, server),
          Wardrik.servers_remove(session, owner, "docs"),
          Wardrik.connections_list(session, owner),
          Wardrik.connections_connect(session, owner, "github"),
          Wardrik.connections_disconnect(session, owner, "github"),
          Wardrik.agent_trigger_deliver(session, agent, "hook", request),
          Wardrik.tokens_list(root),
          Wardrik.tokens_create(root, "ci", root.grant, for: maria()),
          Wardrik.tokens_revoke(root, "t1")
        ],
        do: assert({:error, %Error{type: :unsupported}} = answer)
  end

  test "the deployment answers a session over every agent", %{root: root} do
    assert {:ok, %Wardrik.Deployment.Nodes{nodes: [{node, _count}]}} =
             Wardrik.deployment_nodes(root)

    assert node == node()
    assert {:ok, [^node]} = Wardrik.deployment_reload(root)
    assert {:ok, changes} = Wardrik.deployment_audit(root, limit: 10)
    assert is_list(changes)
  end

  test "each function's ! variant answers the value, or raises the error",
       %{session: session, root: root} do
    owner = Prefix.new!(org: "acme")
    agent = id("bang")
    definition = %{"model" => "anthropic:claude-sonnet-5"}

    assert %Snapshot{} = Wardrik.agent_define!(session, agent, definition)
    assert %Wardrik.Definition.Read{} = Wardrik.agent_definition_read!(session, agent)
    assert %Snapshot{} = Wardrik.agent_read!(session, agent)
    assert [_ | _] = Wardrik.agents_list!(session, Prefix.of(agent))
    assert [] = Wardrik.agents_parked!(session, Prefix.of(agent))
    assert :ok = Wardrik.agent_subscribe!(session, agent)
    assert Enumerable.impl_for(Wardrik.agent_stream!(session, agent))
    assert [_ | _] = Wardrik.agent_events!(session, agent)

    assert %{"name" => "s"} =
             Wardrik.agent_trigger_set!(session, agent, "s", %{
               "every" => "1h",
               "prompt" => "Look."
             })

    assert :ok = Wardrik.agent_trigger_remove!(session, agent, "s")
    assert :ok = Wardrik.agent_clear!(session, agent)
    assert :ok = Wardrik.agent_cancel!(session, agent)
    assert [] = Wardrik.agents_cancel!(session, Prefix.of(agent))
    assert :ok = Wardrik.agent_stop!(session, agent)
    assert %Member{} = Wardrik.agent_spawn!(session, agent)
    assert %Member{} = Wardrik.agent_move!(root, agent, node())
    assert %Wardrik.Deployment.Nodes{} = Wardrik.deployment_nodes!(root)
    assert is_list(Wardrik.deployment_audit!(root))
    assert [_node] = Wardrik.deployment_reload!(root)
    assert :ok = Wardrik.agent_forget!(session, agent)

    parked = parked(session)
    assert %{"call_1" => :approve} = Wardrik.agent_approve!(session, parked, "call_1")
    denied = parked(session)
    assert %{"call_1" => {:deny, _reason}} = Wardrik.agent_deny!(session, denied, "call_1")

    echo = start({AgentRunners, :echo, [self(), "ok"]})
    assert %Message{} = Wardrik.agent_ask!(session, echo, "hi")
    assert %{^echo => :forgotten} = Wardrik.agents_forget!(session, Prefix.of(echo))

    for raising <- [
          fn -> Wardrik.agent_authorization_read!(session, echo, "call_1") end,
          fn -> Wardrik.servers_list!(session, owner) end,
          fn ->
            Wardrik.servers_add!(session, owner, %Server{name: "d", url: "u", auth: "none"})
          end,
          fn -> Wardrik.servers_remove!(session, owner, "d") end,
          fn -> Wardrik.connections_list!(session, owner) end,
          fn -> Wardrik.connections_connect!(session, owner, "github") end,
          fn -> Wardrik.connections_disconnect!(session, owner, "github") end,
          fn -> Wardrik.agent_trigger_deliver!(session, echo, "h", %{headers: [], body: ""}) end,
          fn -> Wardrik.tokens_list!(root) end,
          fn -> Wardrik.tokens_create!(root, "ci", root.grant) end,
          fn -> Wardrik.tokens_revoke!(root, "t1") end
        ],
        do: assert_raise(Error, raising)
  end
end
