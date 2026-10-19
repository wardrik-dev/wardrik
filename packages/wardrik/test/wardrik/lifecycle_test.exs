defmodule Wardrik.LifecycleTest do
  # The host's definitions are kept in the suite's store, and the audit is
  # one for the node, which these tests read.
  use ExUnit.Case, async: false

  import Wardrik.Test, only: [store: 0]

  alias Wardrik.Agent
  alias Wardrik.Agent.Snapshot
  alias Wardrik.AgentID
  alias Wardrik.Definition
  alias Wardrik.Definitions
  alias Wardrik.Error
  alias Wardrik.Event
  alias Wardrik.Fleet.Member
  alias Wardrik.Forgetting
  alias Wardrik.Moving
  alias Wardrik.Principal
  alias Wardrik.Resource
  alias Wardrik.Role
  alias Wardrik.Scope
  alias Wardrik.Spawned
  alias Wardrik.Test.AgentRunners
  alias Wardrik.Test.Audit
  alias Wardrik.Test.Fleet
  alias Wardrik.Test.Script
  alias Wardrik.Token

  # One spawned with no definition is given its defaults' model.
  defp definitions do
    %Wardrik.Definitions{
      store: store(),
      contexts: Wardrik.context(defaults: %{"model" => "openai:gpt-5"})
    }
  end

  # `id` as an agent file declares it.
  defp declared(id) do
    {:ok, definition} =
      Definition.read(%{},
        id: id,
        source: {:file, "agents/#{id.name}.md"},
        context: Definitions.context(definitions(), id)
      )

    :ok = Definitions.put(definitions(), definition)
    on_exit(fn -> Definitions.delete(definitions(), id) end)
    "#{id} is declared by agents/#{id.name}.md; change or remove that file, then reload it"
  end

  @jon %{"type" => "user", "id" => "jon", "name" => "Jon"}

  # Agents run on the model the runtime gives unless they name one.
  defp host,
    do:
      Wardrik.Test.host(
        definitions: definitions(),
        runtimes: [
          %Wardrik.LLM.Runtime{config: [model_spec: "anthropic:claude-sonnet-5"]},
          %Wardrik.Test.Runtime{}
        ]
      )

  defp scope(pattern \\ "test/agent/*", roles \\ [:owner], host \\ host()) do
    Scope.new(host, %Token{
      principal: jon(),
      scope: [Role.bind(roles, [Resource.parse!(pattern)])]
    })
  end

  defp root, do: Scope.new(host(), Token.root(jon()))

  defp jon, do: Principal.new(:user, "jon", name: "Jon")

  defp defined_id(name \\ "defined") do
    id = Fleet.id(name)
    on_exit(fn -> Wardrik.Fleet.forget(id) end)
    id
  end

  # An agent running a turn, which goes on until it is sent `:release`.
  defp busy_agent(id \\ Fleet.id()) do
    {id, agent} =
      Fleet.start_agent(
        [config: Script.new({AgentRunners, :blocking, [self(), "ok"]}), grace: 10],
        id
      )

    :ok = Event.Bus.subscribe(id, level: :lifecycle)
    Agent.ask(agent, "wait")
    assert_receive {:turn, _messages, turn}

    Fleet.await_update(fn ->
      Wardrik.Fleet.lookup(id, host: Wardrik.Test.host()).status != :idle
    end)

    {id, turn}
  end

  describe "defining" do
    test "starts the agent, then brings it to a new definition, each recorded" do
      id = defined_id()

      assert {:ok, %Snapshot{agent: ^id}} = Wardrik.agent_define(scope(), id, %{})
      assert Agent.status(id, host: Wardrik.Test.host()).model == "anthropic:claude-sonnet-5"

      assert {:ok, %Snapshot{}} =
               Wardrik.agent_define(scope(), id, %{"model" => "openai:gpt-5"})

      assert Agent.status(id, host: Wardrik.Test.host()).model == "openai:gpt-5"

      assert {:ok, %{definition: %Definition{fields: %{"model" => "openai:gpt-5"}}, missing: []}} =
               Wardrik.agent_definition_read(scope(), id)

      assert Audit.about(id) == [{"agent.defined", @jon}, {"agent.defined", @jon}]
    end

    test "starts nothing for a definition that does not read, or an agent the host keeps" do
      id = defined_id()

      assert {:error, %Error{type: :invalid, message: "model is a string"}} =
               Wardrik.agent_define(scope(), id, %{"model" => 5})

      owned = defined_id("owned")
      why = declared(owned)

      assert {:error, %Error{type: :conflict, message: ^why}} =
               Wardrik.agent_define(scope(), owned, %{})

      assert Wardrik.Fleet.lookup(id, host: Wardrik.Test.host()) == nil
      assert Wardrik.Fleet.lookup(owned, host: Wardrik.Test.host()) == nil
    end

    test "holds the agent to the hooks held, ahead of its own" do
      id = defined_id()
      held = [Wardrik.Hook.new("held", Wardrik.Test.Tools.Rules, allow: [])]

      assert {:ok, _snapshot} =
               Wardrik.agent_define(scope("test/agent/*", [:definer, :reader]), id, %{},
                 held: held
               )

      %{user_state: state} = :sys.get_state(Wardrik.Fleet.whereis(id, host: Wardrik.Test.host()))
      assert [%Wardrik.Hook{name: "held"}] = Keyword.fetch!(state.run_opts, :hooks)
    end
  end

  describe "triggers" do
    setup do
      id = defined_id("triggered")
      {:ok, _snapshot} = Wardrik.agent_define(scope(), id, %{})
      %{id: id}
    end

    test "are set, changed and removed, and each change recorded", %{id: id} do
      fields = %{"every" => "1h", "prompt" => "Look."}

      assert {:ok, %{"name" => "sweep"}} =
               Wardrik.agent_trigger_set(scope(), id, "sweep", fields)

      assert {:ok, %{"every" => "2h"}} =
               Wardrik.agent_trigger_set(scope(), id, "sweep", %{fields | "every" => "2h"})

      assert {:ok, %{"name" => "sweep", "every" => "2h"}} =
               Wardrik.agent_trigger_remove(scope(), id, "sweep")

      assert {:error, %Error{type: :not_found, message: message}} =
               Wardrik.agent_trigger_remove(scope(), id, "sweep")

      assert message == "#{id} has no trigger sweep."

      assert Audit.about(id) == [
               {"agent.defined", @jon},
               {"trigger.set", @jon},
               {"trigger.set", @jon},
               {"trigger.removed", @jon}
             ]
    end

    test "that do not read, or are for an agent without a definition or owned, are refused",
         %{id: id} do
      assert {:error, %Error{type: :invalid}} =
               Wardrik.agent_trigger_set(scope(), id, "sweep", %{"every" => "1h"})

      assert {:error, %Error{type: :not_found, message: message}} =
               Wardrik.agent_trigger_set(scope(), Fleet.id("nobody"), "s", %{})

      assert message =~ "has no definition kept."

      owned = Fleet.id("owned")
      declared(owned)

      assert {:error, %Error{type: :conflict}} =
               Wardrik.agent_trigger_set(scope(), owned, "s", %{})

      assert {:error, %Error{type: :conflict}} =
               Wardrik.agent_trigger_remove(scope(), owned, "s")
    end
  end

  describe "forgetting" do
    test "previews, then removes the agent with its definition, then finds nothing" do
      id = defined_id()
      {:ok, _snapshot} = Wardrik.agent_define(scope(), id, %{})

      assert {:ok, %Forgetting{agents: [^id], kept: []}} =
               Wardrik.agent_forget_preview(scope(), id)

      assert Audit.about(id) == [{"agent.defined", @jon}]
      assert :ok = Wardrik.agent_forget(scope(), id)
      assert Wardrik.Fleet.lookup(id, host: Wardrik.Test.host()) == nil
      assert List.last(Audit.about(id)) == {"agent.forgotten", @jon}

      assert {:error, %Error{type: :not_found}} = Wardrik.agent_definition_read(scope(), id)
      assert {:error, %Error{type: :not_found}} = Wardrik.agent_forget(scope(), id)
      assert {:error, %Error{type: :not_found}} = Wardrik.agent_forget_preview(scope(), id)
    end

    test "removes an agent the host kept no definition for, unless the host keeps it" do
      {id, _agent} = Fleet.start_agent()
      assert :ok = Wardrik.agent_forget(scope(), id)
      assert Wardrik.Fleet.lookup(id, host: Wardrik.Test.host()) == nil

      {owned, _agent} = Fleet.start_agent([], Fleet.id("owned"))
      why = declared(owned)

      assert {:error, %Error{type: :conflict, message: ^why}} =
               Wardrik.agent_forget_preview(scope(), owned)

      assert {:error, %Error{type: :conflict}} = Wardrik.agent_forget(scope(), owned)
      assert Wardrik.Fleet.lookup(owned, host: Wardrik.Test.host())
    end

    test "by a pattern removes what the host lets go, says why it keeps the rest" do
      org = "forget-#{System.unique_integer([:positive])}"
      pattern = Resource.parse!("#{org}/agent/*")
      {gone, _agent} = Fleet.start_agent([], AgentID.new!("gone", org: org))
      {owned, _agent} = Fleet.start_agent([], AgentID.new!("owned", org: org))
      on_exit(fn -> Wardrik.Fleet.forget(owned) end)
      scope = scope("#{org}/agent/*")
      why = declared(owned)

      assert {:ok, %Forgetting{agents: [^gone], kept: [{^owned, ^why}]}} =
               Wardrik.agents_forget_preview(scope, pattern)

      assert {:ok, %{^gone => :forgotten, ^owned => {:kept, ^why}}} =
               Wardrik.agents_forget(scope, pattern)

      assert Wardrik.Fleet.lookup(gone, host: Wardrik.Test.host()) == nil
      assert Wardrik.Fleet.lookup(owned, host: Wardrik.Test.host())

      subject = to_string(AgentID.resource(gone))

      assert [%{"data" => %{"resource" => resource}}] =
               for(e <- Audit.all(), e["subject"] == subject, do: e)

      assert resource == "#{org}/agent/*"
      assert {:error, %Error{type: :conflict}} = Wardrik.agents_forget(scope, pattern)

      assert {:error, %Error{type: :not_found}} =
               Wardrik.agents_forget_preview(scope(), Resource.parse!("#{org}-none/agent/*"))
    end
  end

  describe "cancelling" do
    test "stops what the agent is doing, and is recorded" do
      {id, _turn} = busy_agent()

      assert :ok = Wardrik.agent_cancel(scope(), id)
      assert_receive %Event{payload: %Event.TurnInterrupted{}}
      assert Audit.about(id) == [{"agent.cancelled", @jon}]

      assert {:error, %Error{type: :not_found}} =
               Wardrik.agent_cancel(scope(), Fleet.id("nobody"))
    end

    test "leaves an agent taking no turn as it is, and records nothing" do
      {id, _agent} = Fleet.start_agent()

      assert :ok = Wardrik.agent_cancel(scope(), id)
      assert Audit.about(id) == []
    end

    test "by a pattern stops each agent taking a turn, recorded as one change" do
      org = "cancel-#{System.unique_integer([:positive])}"
      pattern = Resource.parse!("#{org}/agent/*")
      {busy, _turn} = busy_agent(AgentID.new!("busy", org: org))
      {other, _turn} = busy_agent(AgentID.new!("other", org: org))
      {idle, _agent} = Fleet.start_agent([], AgentID.new!("idle", org: org))

      assert {:ok, cancelled} = Wardrik.agents_cancel(scope("#{org}/agent/*"), pattern)
      assert Enum.sort(cancelled) == Enum.sort([busy, other])
      assert Audit.about(idle) == []

      entries =
        for %{"subject" => subject} = event <- Audit.all(),
            subject in Enum.map([busy, other], &to_string(AgentID.resource(&1))),
            do: event

      assert [%{"traceparent" => trace}, %{"traceparent" => trace}] = entries
      assert Enum.all?(entries, &(&1["data"]["resource"] == "#{org}/agent/*"))
    end

    test "by a pattern outside the scope's token reaches nothing" do
      assert {:error, %Error{type: :not_found}} =
               Wardrik.agents_cancel(scope(), Resource.parse!("other/agent/*"))

      assert {:error, %Error{type: :forbidden}} =
               Wardrik.agents_cancel(
                 scope("test/agent/*", [:reader]),
                 Resource.parse!("test/agent/*")
               )
    end
  end

  test "stopping puts an agent to sleep with its conversation, and leaves one asleep be" do
    {id, _agent} = Fleet.start_agent()

    assert {:ok, %Member{asleep: true}} = Wardrik.agent_stop(scope(), id)
    assert {:ok, %Member{asleep: true}} = Wardrik.agent_stop(scope(), id)
    assert Audit.about(id) == [{"agent.stopped", @jon}]

    assert {:error, %Error{type: :not_found}} = Wardrik.agent_stop(scope(), Fleet.id("nobody"))
  end

  describe "spawning" do
    test "leaves an agent running as it is, and wakes one asleep" do
      {id, _agent} = Fleet.start_agent()

      assert {:ok, %Spawned{from: :running, member: %Member{id: ^id, asleep: false}}} =
               Wardrik.agent_spawn(scope(), id)

      :ok = Wardrik.Fleet.stop(id)

      assert {:ok, %Spawned{from: :store, member: %Member{asleep: false}}} =
               Wardrik.agent_spawn(scope(), id)

      assert Audit.about(id) == [{"agent.spawned", @jon}]
    end

    test "starts an agent on its definition, or defines one nothing defines" do
      id = defined_id()

      {:ok, definition} =
        Definition.read(%{"model" => "openai:gpt-5"},
          id: id,
          source: :defaults,
          context: Definitions.context(definitions(), id)
        )

      :ok = Definitions.put(definitions(), definition)

      assert {:ok, %Spawned{from: :definition, member: %Member{id: ^id}}} =
               Wardrik.agent_spawn(scope(), id)

      assert Agent.status(id, host: Wardrik.Test.host()).model == "openai:gpt-5"

      fresh = defined_id("fresh")
      assert {:ok, %Spawned{from: :new}} = Wardrik.agent_spawn(scope(), fresh)

      assert Agent.status(fresh, host: Wardrik.Test.host()).model == "openai:gpt-5"

      assert {:ok, %Definition{fields: %{"model" => "openai:gpt-5"}, source: :defaults}} =
               Definitions.get(definitions(), fresh)

      assert {:error, %Error{type: :invalid}} =
               Wardrik.agent_spawn(scope(), AgentID.put_external_id(Fleet.id("fresh"), "t1"))
    end

    test "on a node is the deployment's to choose" do
      id = defined_id("placed")

      assert {:ok, %Spawned{member: %Member{node: node}}} =
               Wardrik.agent_spawn(root(), id, node: node())

      assert node == node()
      assert {:error, %Error{type: :forbidden}} = Wardrik.agent_spawn(scope(), id, node: node())

      assert {:error, %Error{type: :invalid}} =
               Wardrik.agent_spawn(root(), id, node: :nowhere@nohost)
    end
  end

  describe "moving" do
    test "previews, and leaves an agent on its node be, interrupting nothing" do
      {id, _turn} = busy_agent()
      here = node()

      assert {:ok, %Moving{agent: ^id, from: ^here, to: ^here, status: :running}} =
               Wardrik.agent_move_preview(root(), id, here)

      assert {:ok, %Member{id: ^id}} = Wardrik.agent_move(root(), id, here)
      assert Audit.about(id) == []

      assert {:error, %Error{type: :forbidden}} = Wardrik.agent_move_preview(scope(), id, here)
      assert {:error, %Error{type: :forbidden}} = Wardrik.agent_move(scope(), id, here)

      assert {:error, %Error{type: :not_found}} =
               Wardrik.agent_move_preview(root(), Fleet.id("nobody"), here)

      assert {:error, %Error{type: :invalid}} = Wardrik.agent_move(root(), id, :nowhere@nohost)
    end

    test "previews an agent asleep as coming from nowhere" do
      {id, _agent} = Fleet.start_agent()
      :ok = Wardrik.Fleet.stop(id)

      assert {:ok, %Moving{from: :asleep, status: :idle}} =
               Wardrik.agent_move_preview(root(), id, node())
    end
  end
end
