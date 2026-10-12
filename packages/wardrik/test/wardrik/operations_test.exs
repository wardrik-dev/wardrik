defmodule Wardrik.OperationsTest do
  # The host's definitions module is one for the node, which these tests set.
  use ExUnit.Case, async: false

  alias ReqLLM.Context
  alias Wardrik.Agent
  alias Wardrik.Agent.Spec
  alias Wardrik.AgentID
  alias Wardrik.AgentID.Prefix
  alias Wardrik.Caller
  alias Wardrik.Command
  alias Wardrik.Error
  alias Wardrik.Event
  alias Wardrik.Event.Log
  alias Wardrik.Grant
  alias Wardrik.LLM.Config
  alias Wardrik.Operations.Ask
  alias Wardrik.Operations.Cancel
  alias Wardrik.Operations.Clear
  alias Wardrik.Operations.Decide
  alias Wardrik.Operations.Define
  alias Wardrik.Operations.Forget
  alias Wardrik.Operations.ReadAgent
  alias Wardrik.Operations.ReadAuthorization
  alias Wardrik.Operations.ReadDefinition
  alias Wardrik.Operations.ReadEvents
  alias Wardrik.Operations.RemoveSchedule
  alias Wardrik.Operations.SetSchedule
  alias Wardrik.Principal
  alias Wardrik.Query
  alias Wardrik.Test.AgentRunners
  alias Wardrik.Test.Audit
  alias Wardrik.Test.EventLog
  alias Wardrik.Test.Fleet

  # Keeps what it is sent in WardrikStore, schedules beside definitions;
  # refuses a definition holding "refuse", writes every spec for
  # test/elsewhere where one holds "elsewhere", and refuses to change an agent
  # whose name holds "-owned".
  defmodule Kept do
    @moduledoc false
    @behaviour Wardrik.Definition

    @ns :operations_test_definitions
    @schedules :operations_test_schedules

    @impl true
    def put(_id, %{"refuse" => message}, _grant), do: {:error, message}
    def put(_id, %{"elsewhere" => true}, _grant), do: {:ok, Spec.new(id: elsewhere())}

    def put(id, fields, _grant) do
      with :ok <- editable(id) do
        {:ok, _vsn} = WardrikStore.put(@ns, to_string(id), fields)
        model = Map.get(fields, "model", "anthropic:claude-sonnet-5")
        {:ok, Spec.new(id: id, config: Config.new(model_spec: model))}
      end
    end

    @impl true
    def get(id) do
      case WardrikStore.get(@ns, to_string(id)) do
        nil -> {:error, :not_found}
        definition -> {:ok, definition}
      end
    end

    @impl true
    def delete(id) do
      with :ok <- editable(id) do
        if get(id) == {:error, :not_found},
          do: {:error, :not_found},
          else: WardrikStore.delete(@ns, to_string(id))
      end
    end

    @impl true
    def put_schedule(_id, _name, %{"refuse" => message}), do: {:error, message}

    def put_schedule(id, name, fields) do
      with :ok <- editable(id),
           {:ok, _definition} <- get(id) do
        status = if WardrikStore.get(@schedules, "#{id}//#{name}"), do: :changed, else: :created
        {:ok, _vsn} = WardrikStore.put(@schedules, "#{id}//#{name}", fields)
        {:ok, status, Map.put(fields, "name", name)}
      end
    end

    @impl true
    def delete_schedule(id, name) do
      with :ok <- editable(id) do
        if WardrikStore.get(@schedules, "#{id}//#{name}"),
          do: WardrikStore.delete(@schedules, "#{id}//#{name}"),
          else: {:error, :not_found}
      end
    end

    def elsewhere, do: AgentID.parse!("test/elsewhere")

    defp editable(id) do
      if String.contains?(id.name, "-owned"),
        do: {:error, :conflict, "#{id} belongs to a file."},
        else: :ok
    end
  end

  # Reads definitions, and keeps none.
  defmodule Reading do
    @moduledoc false
    @behaviour Wardrik.Definition

    @impl true
    def put(id, _fields, _grant), do: {:ok, Spec.new(id: id)}
  end

  @jon %{"type" => "user", "id" => "jon", "name" => "Jon"}

  setup do
    definitions(Kept)
    on_exit(fn -> definitions(nil) end)
  end

  defp definitions(module), do: :ignore = Wardrik.Definition.configure(module)

  defp caller(scope \\ "test/", can \\ Grant.actions()) do
    {:ok, grant} = Grant.new(Prefix.parse!(scope), can)
    Caller.new(Principal.new(:user, "jon", name: "Jon"), grant)
  end

  defp defined_id(name \\ "defined") do
    id = Fleet.id(name)
    on_exit(fn -> Wardrik.Fleet.forget(id) end)
    id
  end

  defp parked_agent do
    {id, agent} =
      Fleet.start_agent(
        runner: {AgentRunners, :parking, [self(), "call_1"]},
        resumer: {AgentRunners, :resuming, [self(), {:ok, [Context.assistant("shipped")]}]}
      )

    :ok = Event.Bus.subscribe(id, level: :lifecycle)
    Agent.ask(agent, "ship it")
    assert_receive %Event{payload: %Event.TurnParked{}}
    id
  end

  # An agent running a turn, which goes on until it is sent `:release`.
  defp busy_agent do
    {id, agent} = Fleet.start_agent(runner: {AgentRunners, :blocking, [self(), "ok"]}, grace: 10)
    :ok = Event.Bus.subscribe(id, level: :lifecycle)
    Agent.ask(agent, "wait")
    assert_receive {:turn, _messages, turn}
    {id, turn}
  end

  describe "a query" do
    test "reads what the caller's grant reaches and allows" do
      {id, _agent} = Fleet.start_agent()

      assert {:ok, %{"agent" => %{"id" => text}}} =
               Query.run(%ReadAgent{agent: id}, caller("test/", [:read]))

      assert text == to_string(id)
    end

    test "finds nothing outside the caller's scope, and refuses what its grant does not allow" do
      {id, _agent} = Fleet.start_agent()

      assert {:error, %Error{type: :not_found}} =
               Query.run(%ReadAgent{agent: id}, caller("other/", [:read]))

      assert {:error, %Error{type: :forbidden, message: message}} =
               Query.run(%ReadAgent{agent: id}, caller("test/", [:message]))

      assert message == "This caller may not read #{id}."

      assert {:error, %Error{type: :not_found}} =
               Query.run(%ReadAgent{agent: Fleet.id("nobody")}, caller())
    end
  end

  describe "a command" do
    test "changes nothing as it is planned, and is recorded once it is made" do
      {id, _agent} = Fleet.start_agent()

      assert {:ok, change} = Command.plan(%Clear{agent: id}, caller())
      assert Audit.about("agents/#{id}") == []

      assert {:ok, nil} = Command.make(change, caller())
      assert Audit.about("agents/#{id}") == [{"agent.cleared", @jon}]
    end

    test "is made only where the caller's grant still allows it" do
      {id, _agent} = Fleet.start_agent()
      {:ok, change} = Command.plan(%Clear{agent: id}, caller())

      assert {:error, %Error{type: :forbidden}} = Command.make(change, caller("test/", [:read]))
      assert Audit.about("agents/#{id}") == []
    end

    test "that fails is not recorded" do
      id = Fleet.id("nobody")

      assert {:error, %Error{type: :not_found}} = Command.run(%Clear{agent: id}, caller())
      assert Audit.about("agents/#{id}") == []
    end
  end

  describe "reading events" do
    test "answers a page after a sequence, and where the log now starts" do
      {id, agent} = Fleet.start_agent(runner: {AgentRunners, :echo, [self(), "ok"]})
      :ok = Event.Bus.subscribe(id, level: :lifecycle)
      Agent.ask(agent, "hi")
      assert_receive %Event{payload: %Event.TurnFinished{}}

      assert {:ok, %{"events" => [_first, _second]}} =
               Query.run(%ReadEvents{agent: id, limit: 2}, caller())

      :ok = Log.trim(id, 2, DateTime.add(DateTime.utc_now(), 1, :day))

      assert {:error, %Error{type: :gap, details: %{"oldest" => 3}}} =
               Query.run(%ReadEvents{agent: id, limit: 2}, caller())
    end
  end

  describe "reading an authorization" do
    test "answers where a person authorizes the call, and only that" do
      link = %{url: "https://github.com/login/device", code: "WDJB-MJHT"}

      {id, agent} =
        Fleet.start_agent(runner: {AgentRunners, :connecting, [self(), "call_1", link]})

      :ok = Event.Bus.subscribe(id, level: :lifecycle)
      Agent.ask(agent, "open an issue")
      assert_receive %Event{payload: %Event.TurnParked{}}

      assert {:ok, %{"url" => "https://github.com/login/device", "code" => "WDJB-MJHT"}} =
               Query.run(%ReadAuthorization{agent: id, interrupt: "call_1"}, caller())

      assert {:error, %Error{type: :not_found}} =
               Query.run(%ReadAuthorization{agent: id, interrupt: "nope"}, caller())

      assert {:error, %Error{type: :forbidden}} =
               Query.run(
                 %ReadAuthorization{agent: id, interrupt: "call_1"},
                 caller("test/", [:read])
               )
    end

    test "has none for a call that waits on a decision, or an agent not running" do
      id = parked_agent()

      assert {:error, %Error{type: :not_found, message: "call_1 waits on no authorization."}} =
               Query.run(%ReadAuthorization{agent: id, interrupt: "call_1"}, caller())

      assert {:error, %Error{type: :not_found}} =
               Query.run(
                 %ReadAuthorization{agent: Fleet.id("nobody"), interrupt: "call_1"},
                 caller()
               )
    end
  end

  describe "asking" do
    test "reads a message's text, from its parts or its content" do
      id = Fleet.id()

      assert {:ok, %Ask{id: "m1", text: "a\nb"}} =
               Ask.new(id, %{
                 "id" => "m1",
                 "parts" => [
                   %{"type" => "text", "content" => "a"},
                   %{"type" => "text", "content" => "b"}
                 ]
               })

      assert {:ok, %Ask{text: "hi", id: made}} = Ask.new(id, %{"content" => "hi"})
      assert is_binary(made)

      for message <- [%{}, %{"content" => ""}, %{"content" => "hi", "id" => 7}] do
        assert {:error, %Error{type: :invalid}} = Ask.new(id, message)
      end
    end

    test "sends the agent the message, which says its ID" do
      {id, _agent} = Fleet.start_agent(runner: {AgentRunners, :echo, [self(), "ok"]})
      {:ok, ask} = Ask.new(id, %{"id" => "m1", "content" => "hi"})

      assert {:ok, %{"message" => %{"id" => "m1"}}} = Command.run(ask, caller())
      assert_receive {:turn, _messages}

      {:ok, nobody} = Ask.new(Fleet.id("nobody"), %{"content" => "hi"})
      assert {:error, %Error{type: :not_found}} = Command.run(nobody, caller())
    end
  end

  describe "deciding" do
    test "reads an approval, with its note, or a rejection, with its reason" do
      id = Fleet.id()

      assert {:ok, %Decide{decision: :approve}} = Decide.new(id, "c", %{"decision" => "approve"})

      assert {:ok, %Decide{decision: {:approve, "Only staging."}}} =
               Decide.new(id, "c", %{"decision" => "approve", "note" => "Only staging."})

      assert {:ok, %Decide{decision: {:deny, "Not now."}}} =
               Decide.new(id, "c", %{"decision" => "reject", "reason" => "Not now."})

      assert {:ok, %Decide{decision: {:deny, _given}}} =
               Decide.new(id, "c", %{"decision" => "reject"})

      assert {:error, %Error{type: :invalid}} = Decide.new(id, "c", %{"decision" => "maybe"})
    end

    test "decides a call the agent waits on, as the caller" do
      id = parked_agent()
      {:ok, decide} = Decide.new(id, "call_1", %{"decision" => "reject", "reason" => "No."})

      assert {:ok, %{"interrupt" => %{"id" => "call_1", "decision" => "rejected"}}} =
               Command.run(decide, caller())

      assert_receive %Event{payload: %Event.CallDecided{call_id: "call_1", by: by}}
      assert Principal.id(by) == "jon"
      assert {:error, %Error{type: :conflict}} = Command.run(decide, caller())
    end

    test "refuses a call the agent does not wait on, or an agent not running" do
      id = parked_agent()
      {:ok, stale} = Decide.new(id, "call_9", %{"decision" => "approve"})
      assert {:error, %Error{type: :conflict}} = Command.run(stale, caller())

      {:ok, nobody} = Decide.new(Fleet.id("nobody"), "call_1", %{"decision" => "approve"})
      assert {:error, %Error{type: :not_found}} = Command.run(nobody, caller())
    end

    test "says so where the agent cannot record the decision" do
      id = parked_agent()
      :ok = EventLog.usurp(id)
      {:ok, decide} = Decide.new(id, "call_1", %{"decision" => "approve"})

      assert {:error, %Error{type: :unavailable}} = Command.run(decide, caller())
    end
  end

  describe "cancelling" do
    test "stops what the agent is doing, and is recorded" do
      {id, _turn} = busy_agent()

      assert {:ok, %{"agent" => %{"id" => text}}} = Command.run(%Cancel{agent: id}, caller())
      assert text == to_string(id)
      assert_receive %Event{payload: %Event.TurnInterrupted{}}
      assert Audit.about("agents/#{id}") == [{"agent.cancelled", @jon}]

      assert {:error, %Error{type: :not_found}} =
               Command.run(%Cancel{agent: Fleet.id("nobody")}, caller())
    end
  end

  describe "clearing" do
    test "waits while a turn runs" do
      {id, turn} = busy_agent()

      assert {:error, %Error{type: :conflict}} = Command.run(%Clear{agent: id}, caller())
      send(turn, :release)
      assert_receive %Event{payload: %Event.TurnFinished{}}

      assert {:ok, nil} = Command.run(%Clear{agent: id}, caller())
    end
  end

  describe "defining" do
    test "starts the agent, then brings it to a new definition" do
      id = defined_id()

      assert {:created, %{"request" => %{"model" => "claude-sonnet-5"}}} =
               Command.run(%Define{agent: id, definition: %{}}, caller())

      assert {:ok, %{"request" => %{"model" => "gpt-5"}}} =
               Command.run(%Define{agent: id, definition: %{"model" => "openai:gpt-5"}}, caller())

      assert {:ok, %{"model" => "openai:gpt-5"}} =
               Query.run(%ReadDefinition{agent: id}, caller())

      assert Audit.about("agents/#{id}") ==
               [{"agent.defined", @jon}, {"agent.defined", @jon}]
    end

    test "starts nothing for a definition that does not read, or an agent the host keeps" do
      id = defined_id()

      assert {:error, %Error{type: :invalid, message: "model is text"}} =
               Command.run(
                 %Define{agent: id, definition: %{"refuse" => "model is text"}},
                 caller()
               )

      owned = defined_id("kept-owned")

      assert {:error, %Error{type: :conflict}} =
               Command.run(%Define{agent: owned, definition: %{}}, caller())

      assert Wardrik.Fleet.lookup(id) == nil
      assert Wardrik.Fleet.lookup(owned) == nil
    end

    test "never starts another agent than the one defined" do
      id = defined_id()

      assert_raise ArgumentError, ~r"wrote a spec for test/elsewhere, not #{id}", fn ->
        Command.run(%Define{agent: id, definition: %{"elsewhere" => true}}, caller())
      end

      assert Wardrik.Fleet.lookup(Kept.elsewhere()) == nil
    end

    test "holds the agent to the caller's ceiling ahead of its own hooks" do
      id = defined_id()
      ceiling = [Wardrik.Hook.new("ceiling", Wardrik.Test.Tools.Rules, allow: [])]
      {:ok, grant} = Grant.new(Prefix.parse!("test/"), [:define, :read], ceiling)

      assert {:created, _snapshot} =
               Command.run(%Define{agent: id, definition: %{}}, Caller.new(nil, grant))

      %{user_state: state} = :sys.get_state(Wardrik.Fleet.whereis(id))
      assert [%Wardrik.Hook{name: "ceiling"}] = Keyword.fetch!(state.scope_opts, :hooks)
    end
  end

  describe "forgetting" do
    test "removes the agent with its definition, then finds nothing" do
      id = defined_id()
      {:created, _snapshot} = Command.run(%Define{agent: id, definition: %{}}, caller())

      assert {:ok, nil} = Command.run(%Forget{agent: id}, caller())
      assert Wardrik.Fleet.lookup(id) == nil
      assert {:error, %Error{type: :not_found}} = Query.run(%ReadDefinition{agent: id}, caller())
      assert {:error, %Error{type: :not_found}} = Command.run(%Forget{agent: id}, caller())
    end

    test "removes an agent the host kept no definition for, unless the host refuses" do
      {id, _agent} = Fleet.start_agent()
      assert {:ok, nil} = Command.run(%Forget{agent: id}, caller())
      assert Wardrik.Fleet.lookup(id) == nil

      {owned, _agent} = Fleet.start_agent([], Fleet.id("kept-owned"))
      assert {:error, %Error{type: :conflict}} = Command.run(%Forget{agent: owned}, caller())
      assert Wardrik.Fleet.lookup(owned)
    end
  end

  describe "schedules" do
    setup do
      id = defined_id("scheduled")
      {:created, _snapshot} = Command.run(%Define{agent: id, definition: %{}}, caller())
      %{id: id}
    end

    test "are set, changed and removed, and each change recorded", %{id: id} do
      fields = %{"every" => "1h", "prompt" => "Look."}

      assert {:created, %{"schedule" => %{"name" => "sweep"}}} =
               Command.run(%SetSchedule{agent: id, name: "sweep", fields: fields}, caller())

      assert {:ok, %{"schedule" => %{"every" => "2h"}}} =
               Command.run(
                 %SetSchedule{agent: id, name: "sweep", fields: %{fields | "every" => "2h"}},
                 caller()
               )

      assert {:ok, nil} = Command.run(%RemoveSchedule{agent: id, name: "sweep"}, caller())

      assert {:error, %Error{type: :not_found, message: message}} =
               Command.run(%RemoveSchedule{agent: id, name: "sweep"}, caller())

      assert message == "#{id} has no schedule sweep."

      assert Audit.about("agents/#{id}") == [
               {"agent.defined", @jon},
               {"schedule.set", @jon},
               {"schedule.set", @jon},
               {"schedule.removed", @jon}
             ]
    end

    test "that do not read, or are for an agent without a definition or owned, are refused",
         %{id: id} do
      assert {:error, %Error{type: :invalid}} =
               Command.run(
                 %SetSchedule{agent: id, name: "sweep", fields: %{"refuse" => "no time"}},
                 caller()
               )

      assert {:error, %Error{type: :not_found, message: message}} =
               Command.run(
                 %SetSchedule{agent: Fleet.id("nobody"), name: "s", fields: %{}},
                 caller()
               )

      assert message =~ "has no definition kept."

      owned = Fleet.id("kept-owned")

      assert {:error, %Error{type: :conflict}} =
               Command.run(%SetSchedule{agent: owned, name: "s", fields: %{}}, caller())

      assert {:error, %Error{type: :conflict}} =
               Command.run(%RemoveSchedule{agent: owned, name: "s"}, caller())
    end
  end

  describe "a host without a definitions module, or one that only reads" do
    test "defines, keeps, forgets and schedules nothing" do
      {id, _agent} = Fleet.start_agent()

      for module <- [nil, Reading] do
        definitions(module)

        assert {:error, %Error{type: :unsupported}} =
                 Query.run(%ReadDefinition{agent: id}, caller())

        assert {:error, %Error{type: :unsupported}} = Command.run(%Forget{agent: id}, caller())

        assert {:error, %Error{type: :unsupported}} =
                 Command.run(%SetSchedule{agent: id, name: "s", fields: %{}}, caller())

        assert {:error, %Error{type: :unsupported}} =
                 Command.run(%RemoveSchedule{agent: id, name: "s"}, caller())
      end

      definitions(nil)

      assert {:error, %Error{type: :unsupported}} =
               Command.run(%Define{agent: id, definition: %{}}, caller())

      assert Wardrik.Fleet.lookup(id)
    end
  end
end
