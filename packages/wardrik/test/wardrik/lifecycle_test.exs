defmodule Wardrik.LifecycleTest do
  # The host's definitions are kept in the suite's store, and the audit is
  # one for the node, which these tests read.
  use ExUnit.Case, async: false

  import Wardrik.Test, only: [store: 0]

  alias Wardrik.Agent
  alias Wardrik.Agent.Snapshot
  alias Wardrik.Agent.Spec
  alias Wardrik.AgentID
  alias Wardrik.AgentID.Prefix
  alias Wardrik.Error
  alias Wardrik.Event
  alias Wardrik.Fleet.Member
  alias Wardrik.Forgetting
  alias Wardrik.Host
  alias Wardrik.LLM.Config
  alias Wardrik.Moving
  alias Wardrik.Principal
  alias Wardrik.Role
  alias Wardrik.Scope
  alias Wardrik.Spawned
  alias Wardrik.Test.AgentRunners
  alias Wardrik.Test.Audit
  alias Wardrik.Test.Fleet
  alias Wardrik.Token

  # Keeps what it is sent in the suite's store, triggers beside definitions;
  # refuses a definition holding "refuse", writes every spec for
  # test/elsewhere where one holds "elsewhere", and refuses to change an agent
  # whose name holds "-owned".
  defmodule Kept do
    @moduledoc false
    defstruct []

    @ns :lifecycle_test_definitions
    @triggers :lifecycle_test_triggers

    def put(_definitions, _id, definition: %{"refuse" => message}, token: _token, held: _held),
      do: {:error, message}

    def put(_definitions, _id, definition: %{"elsewhere" => true}, token: _token, held: _held),
      do: {:ok, Spec.new(id: elsewhere())}

    def put(host, id, definition: fields, token: _token, held: _held) do
      with :ok <- editable(host, id) do
        {:ok, _vsn} = WardrikStore.put(store(), @ns, to_string(id), fields)
        {:ok, spec(id, fields)}
      end
    end

    def get(_host, id) do
      case WardrikStore.get(store(), @ns, to_string(id)) do
        nil -> {:error, :not_found}
        fields -> {:ok, %Wardrik.Definition.Read{fields: fields, missing: []}}
      end
    end

    def delete(host, id) do
      with :ok <- editable(host, id) do
        if get(host, id) == {:error, :not_found},
          do: {:error, :not_found},
          else: WardrikStore.delete(store(), @ns, to_string(id))
      end
    end

    def put_trigger(_definitions, _id, _name, fields: %{"refuse" => message}),
      do: {:error, message}

    def put_trigger(host, id, name, fields: fields) do
      with :ok <- editable(host, id),
           {:ok, _definition} <- get(host, id) do
        status =
          if WardrikStore.get(store(), @triggers, "#{id}//#{name}"), do: :changed, else: :created

        {:ok, _vsn} = WardrikStore.put(store(), @triggers, "#{id}//#{name}", fields)
        {:ok, status, Map.put(fields, "name", name)}
      end
    end

    def delete_trigger(host, id, name) do
      with :ok <- editable(host, id) do
        case WardrikStore.get(store(), @triggers, "#{id}//#{name}") do
          nil ->
            {:error, :not_found}

          fields ->
            :ok = WardrikStore.delete(store(), @triggers, "#{id}//#{name}")
            {:ok, Map.put(fields, "name", name)}
        end
      end
    end

    def current(host, id) do
      case get(host, id) do
        {:ok, %Wardrik.Definition.Read{fields: fields}} -> {:ok, spec(id, fields)}
        {:error, :not_found} -> :none
      end
    end

    def create(host, id) do
      with {:ok, _spec} <-
             put(host, id, definition: %{"model" => "openai:gpt-5"}, token: nil, held: []),
           do: {:ok, spec(id, %{"model" => "openai:gpt-5"})}
    end

    defp spec(id, fields),
      do:
        Spec.new(
          id: id,
          config: Config.new(model_spec: Map.get(fields, "model", "anthropic:claude-sonnet-5"))
        )

    def elsewhere, do: AgentID.parse!("test/elsewhere")

    def editable(_host, id) do
      if String.contains?(id.name, "-owned"),
        do: {:error, :conflict, "#{id} belongs to a file."},
        else: :ok
    end
  end

  defimpl Wardrik.Definition, for: Kept do
    use Wardrik.Definition.None
    defdelegate put(a0, a1, a2), to: Kept
    defdelegate get(a0, a1), to: Kept
    defdelegate delete(a0, a1), to: Kept
    defdelegate put_trigger(a0, a1, a2, a3), to: Kept
    defdelegate delete_trigger(a0, a1, a2), to: Kept
    defdelegate current(a0, a1), to: Kept
    defdelegate create(a0, a1), to: Kept
    defdelegate editable(a0, a1), to: Kept
  end

  # Reads definitions, and keeps none.
  defmodule Reading do
    @moduledoc false
    defstruct []
    def put(_definitions, id, _opts), do: {:ok, Spec.new(id: id)}
  end

  defimpl Wardrik.Definition, for: Reading do
    use Wardrik.Definition.None
    defdelegate put(a0, a1, a2), to: Reading
  end

  @jon %{"type" => "user", "id" => "jon", "name" => "Jon"}

  defp host(definitions \\ %Kept{}), do: Wardrik.Test.host(definitions: definitions)

  defp scope(prefix \\ "test/", roles \\ [:owner], host \\ host()) do
    Scope.new(host, %Token{principal: jon(), scope: [Role.bind(roles, Prefix.parse!(prefix))]})
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
      Fleet.start_agent([runner: {AgentRunners, :blocking, [self(), "ok"]}, grace: 10], id)

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

      assert {:ok, %Wardrik.Definition.Read{fields: %{"model" => "openai:gpt-5"}}} =
               Wardrik.agent_definition_read(scope(), id)

      assert Audit.about("agents/#{id}") == [{"agent.defined", @jon}, {"agent.defined", @jon}]
    end

    test "starts nothing for a definition that does not read, or an agent the host keeps" do
      id = defined_id()

      assert {:error, %Error{type: :invalid, message: "model is text"}} =
               Wardrik.agent_define(scope(), id, %{"refuse" => "model is text"})

      owned = defined_id("kept-owned")
      assert {:error, %Error{type: :conflict}} = Wardrik.agent_define(scope(), owned, %{})
      assert Wardrik.Fleet.lookup(id, host: Wardrik.Test.host()) == nil
      assert Wardrik.Fleet.lookup(owned, host: Wardrik.Test.host()) == nil
    end

    test "never starts another agent than the one defined" do
      id = defined_id()

      assert_raise ArgumentError, ~r"wrote a spec for test/elsewhere, not #{id}", fn ->
        Wardrik.agent_define(scope(), id, %{"elsewhere" => true})
      end

      assert Wardrik.Fleet.lookup(Kept.elsewhere(), host: Wardrik.Test.host()) == nil
    end

    test "holds the agent to the hooks held, ahead of its own" do
      id = defined_id()
      held = [Wardrik.Hook.new("held", Wardrik.Test.Tools.Rules, allow: [])]

      assert {:ok, _snapshot} =
               Wardrik.agent_define(scope("test/", [:definer, :reader]), id, %{}, held: held)

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

      assert Audit.about("agents/#{id}") == [
               {"agent.defined", @jon},
               {"trigger.set", @jon},
               {"trigger.set", @jon},
               {"trigger.removed", @jon}
             ]
    end

    test "that do not read, or are for an agent without a definition or owned, are refused",
         %{id: id} do
      assert {:error, %Error{type: :invalid}} =
               Wardrik.agent_trigger_set(scope(), id, "sweep", %{"refuse" => "no time"})

      assert {:error, %Error{type: :not_found, message: message}} =
               Wardrik.agent_trigger_set(scope(), Fleet.id("nobody"), "s", %{})

      assert message =~ "has no definition kept."

      owned = Fleet.id("kept-owned")

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

      assert Audit.about("agents/#{id}") == [{"agent.defined", @jon}]
      assert :ok = Wardrik.agent_forget(scope(), id)
      assert Wardrik.Fleet.lookup(id, host: Wardrik.Test.host()) == nil
      assert List.last(Audit.about("agents/#{id}")) == {"agent.forgotten", @jon}

      assert {:error, %Error{type: :not_found}} = Wardrik.agent_definition_read(scope(), id)
      assert {:error, %Error{type: :not_found}} = Wardrik.agent_forget(scope(), id)
      assert {:error, %Error{type: :not_found}} = Wardrik.agent_forget_preview(scope(), id)
    end

    test "removes an agent the host kept no definition for, unless the host keeps it" do
      {id, _agent} = Fleet.start_agent()
      assert :ok = Wardrik.agent_forget(scope(), id)
      assert Wardrik.Fleet.lookup(id, host: Wardrik.Test.host()) == nil

      {owned, _agent} = Fleet.start_agent([], Fleet.id("kept-owned"))

      assert {:error, %Error{type: :conflict, message: message}} =
               Wardrik.agent_forget_preview(scope(), owned)

      assert message == "#{owned} belongs to a file."
      assert {:error, %Error{type: :conflict}} = Wardrik.agent_forget(scope(), owned)
      assert Wardrik.Fleet.lookup(owned, host: Wardrik.Test.host())
    end

    test "under a prefix removes what the host lets go, says why it keeps the rest" do
      org = "forget-#{System.unique_integer([:positive])}"
      prefix = Prefix.new!(org: org)
      {gone, _agent} = Fleet.start_agent([], AgentID.new!("gone", org: org))
      {owned, _agent} = Fleet.start_agent([], AgentID.new!("kept-owned", org: org))
      on_exit(fn -> Wardrik.Fleet.forget(owned) end)
      scope = scope("#{org}/")
      why = "#{owned} belongs to a file."

      assert {:ok, %Forgetting{agents: [^gone], kept: [{^owned, ^why}]}} =
               Wardrik.agents_forget_preview(scope, prefix)

      assert {:ok, %{^gone => :forgotten, ^owned => {:kept, ^why}}} =
               Wardrik.agents_forget(scope, prefix)

      assert Wardrik.Fleet.lookup(gone, host: Wardrik.Test.host()) == nil
      assert Wardrik.Fleet.lookup(owned, host: Wardrik.Test.host())

      assert [%{"data" => %{"under" => under}}] =
               for(e <- Audit.all(), e["subject"] == "agents/#{gone}", do: e)

      assert under == "#{org}/"
      assert {:error, %Error{type: :conflict}} = Wardrik.agents_forget(scope, prefix)

      assert {:error, %Error{type: :not_found}} =
               Wardrik.agents_forget_preview(scope(), Prefix.new!(org: "#{org}-none"))
    end
  end

  describe "cancelling" do
    test "stops what the agent is doing, and is recorded" do
      {id, _turn} = busy_agent()

      assert :ok = Wardrik.agent_cancel(scope(), id)
      assert_receive %Event{payload: %Event.TurnInterrupted{}}
      assert Audit.about("agents/#{id}") == [{"agent.cancelled", @jon}]

      assert {:error, %Error{type: :not_found}} =
               Wardrik.agent_cancel(scope(), Fleet.id("nobody"))
    end

    test "leaves an agent taking no turn as it is, and records nothing" do
      {id, _agent} = Fleet.start_agent()

      assert :ok = Wardrik.agent_cancel(scope(), id)
      assert Audit.about("agents/#{id}") == []
    end

    test "under a prefix stops each agent taking a turn, recorded as one change" do
      org = "cancel-#{System.unique_integer([:positive])}"
      prefix = Prefix.new!(org: org)
      {busy, _turn} = busy_agent(AgentID.new!("busy", org: org))
      {other, _turn} = busy_agent(AgentID.new!("other", org: org))
      {idle, _agent} = Fleet.start_agent([], AgentID.new!("idle", org: org))

      assert {:ok, cancelled} = Wardrik.agents_cancel(scope("#{org}/"), prefix)
      assert Enum.sort(cancelled) == Enum.sort([busy, other])
      assert Audit.about("agents/#{idle}") == []

      entries =
        for %{"subject" => "agents/" <> agent} = event <- Audit.all(),
            agent in [to_string(busy), to_string(other)],
            do: event

      assert [%{"traceparent" => trace}, %{"traceparent" => trace}] = entries
      assert Enum.all?(entries, &(&1["data"]["under"] == "#{org}/"))
    end

    test "under a prefix outside the scope's token reaches nothing" do
      assert {:error, %Error{type: :not_found}} =
               Wardrik.agents_cancel(scope(), Prefix.new!(org: "other"))

      assert {:error, %Error{type: :forbidden}} =
               Wardrik.agents_cancel(scope("test/", [:reader]), Prefix.parse!("test/"))
    end
  end

  test "stopping puts an agent to sleep with its conversation, and leaves one asleep be" do
    {id, _agent} = Fleet.start_agent()

    assert {:ok, %Member{asleep: true}} = Wardrik.agent_stop(scope(), id)
    assert {:ok, %Member{asleep: true}} = Wardrik.agent_stop(scope(), id)
    assert Audit.about("agents/#{id}") == [{"agent.stopped", @jon}]

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

      assert Audit.about("agents/#{id}") == [{"agent.spawned", @jon}]
    end

    test "starts an agent on its definition, or defines one nothing defines" do
      id = defined_id()

      {:ok, _vsn} =
        WardrikStore.put(store(), :lifecycle_test_definitions, to_string(id), %{
          "model" => "openai:gpt-5"
        })

      assert {:ok, %Spawned{from: :definition, member: %Member{id: ^id}}} =
               Wardrik.agent_spawn(scope(), id)

      assert Agent.status(id, host: Wardrik.Test.host()).model == "openai:gpt-5"

      fresh = defined_id("fresh")
      assert {:ok, %Spawned{from: :new}} = Wardrik.agent_spawn(scope(), fresh)

      assert {:ok, %Wardrik.Definition.Read{fields: %{"model" => "openai:gpt-5"}}} =
               Kept.get(%Kept{}, fresh)

      owned = defined_id("fresh-owned")
      assert {:error, %Error{type: :conflict}} = Wardrik.agent_spawn(scope(), owned)
    end

    test "finds nothing to start where nothing defines it and the host creates none" do
      assert {:error, %Error{type: :not_found}} =
               Wardrik.agent_spawn(scope("test/", [:owner], Host.new()), Fleet.id())
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
      assert Audit.about("agents/#{id}") == []

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

  test "a host without a definitions module, or one that only reads, defines and keeps nothing" do
    {id, _agent} = Fleet.start_agent()

    for definitions <- [%Wardrik.Definition.None{}, %Reading{}] do
      scope = scope("test/", [:owner], host(definitions))

      assert {:error, %Error{type: :unsupported}} = Wardrik.agent_definition_read(scope, id)

      assert {:error, %Error{type: :unsupported}} =
               Wardrik.agent_trigger_set(scope, id, "s", %{})

      assert {:error, %Error{type: :unsupported}} = Wardrik.agent_trigger_remove(scope, id, "s")
    end

    none = scope("test/", [:owner], Host.new())
    assert {:error, %Error{type: :unsupported}} = Wardrik.agent_define(none, id, %{})
    assert Wardrik.Fleet.lookup(id, host: Wardrik.Test.host())

    assert :ok = Wardrik.agent_forget(none, id)
    assert Wardrik.Fleet.lookup(id, host: Wardrik.Test.host()) == nil
  end
end
