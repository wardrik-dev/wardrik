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
  alias Wardrik.Host
  alias Wardrik.LLM.Config
  alias Wardrik.Operations.Ask
  alias Wardrik.Operations.Cancel
  alias Wardrik.Operations.CancelAgents
  alias Wardrik.Operations.Clear
  alias Wardrik.Operations.Decide
  alias Wardrik.Operations.Define
  alias Wardrik.Operations.Forget
  alias Wardrik.Operations.ForgetAgents
  alias Wardrik.Operations.ListAgents
  alias Wardrik.Operations.ListParked
  alias Wardrik.Operations.Move
  alias Wardrik.Operations.ReadAgent
  alias Wardrik.Operations.ReadAuthorization
  alias Wardrik.Operations.ReadDefinition
  alias Wardrik.Operations.ReadEvents
  alias Wardrik.Operations.RemoveTrigger
  alias Wardrik.Operations.SetTrigger
  alias Wardrik.Operations.Spawn
  alias Wardrik.Operations.SpawnOn
  alias Wardrik.Operations.Stop
  alias Wardrik.Principal
  alias Wardrik.Query
  alias Wardrik.Test.AgentRunners
  alias Wardrik.Test.Audit
  alias Wardrik.Test.EventLog
  alias Wardrik.Test.Fleet

  # Keeps what it is sent in WardrikStore, triggers beside definitions;
  # refuses a definition holding "refuse", writes every spec for
  # test/elsewhere where one holds "elsewhere", and refuses to change an agent
  # whose name holds "-owned".
  defmodule Kept do
    @moduledoc false
    use Wardrik.Definition

    @ns :operations_test_definitions
    @triggers :operations_test_triggers

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
    def put_trigger(_id, _name, %{"refuse" => message}), do: {:error, message}

    def put_trigger(id, name, fields) do
      with :ok <- editable(id),
           {:ok, _definition} <- get(id) do
        status = if WardrikStore.get(@triggers, "#{id}//#{name}"), do: :changed, else: :created
        {:ok, _vsn} = WardrikStore.put(@triggers, "#{id}//#{name}", fields)
        {:ok, status, Map.put(fields, "name", name)}
      end
    end

    @impl true
    def delete_trigger(id, name) do
      with :ok <- editable(id) do
        if WardrikStore.get(@triggers, "#{id}//#{name}"),
          do: WardrikStore.delete(@triggers, "#{id}//#{name}"),
          else: {:error, :not_found}
      end
    end

    @impl true
    def current(id) do
      case get(id) do
        {:ok, fields} -> {:ok, spec(id, fields)}
        {:error, :not_found} -> :none
      end
    end

    @impl true
    def create(id) do
      with {:ok, _spec} <- put(id, %{"model" => "openai:gpt-5"}, nil),
           do: {:ok, spec(id, %{"model" => "openai:gpt-5"})}
    end

    defp spec(id, fields),
      do:
        Spec.new(
          id: id,
          config: Config.new(model_spec: Map.get(fields, "model", "anthropic:claude-sonnet-5"))
        )

    def elsewhere, do: AgentID.parse!("test/elsewhere")

    @impl true
    def editable(id) do
      if String.contains?(id.name, "-owned"),
        do: {:error, :conflict, "#{id} belongs to a file."},
        else: :ok
    end
  end

  # Reads definitions, and keeps none.
  defmodule Reading do
    @moduledoc false
    use Wardrik.Definition

    @impl true
    def put(id, _fields, _grant), do: {:ok, Spec.new(id: id)}
  end

  @jon %{"type" => "user", "id" => "jon", "name" => "Jon"}

  defp host(definitions \\ Kept), do: Host.new(definitions: definitions)

  defp caller(scope \\ "test/", can \\ Grant.actions(), host \\ host()) do
    {:ok, grant} = Grant.new(Prefix.parse!(scope), can)
    Caller.new(principal: Principal.new(:user, "jon", name: "Jon"), grant: grant, host: host)
  end

  defp root, do: Caller.root(principal: Principal.new(:user, "jon", name: "Jon"), host: host())

  defp defined_id(name \\ "defined") do
    id = Fleet.id(name)
    on_exit(fn -> Wardrik.Fleet.forget(id) end)
    id
  end

  defp parked_agent(sender \\ nil) do
    {id, agent} =
      Fleet.start_agent(
        runner: {AgentRunners, :parking, [self(), "call_1"]},
        resumer: {AgentRunners, :resuming, [self(), {:ok, [Context.assistant("shipped")]}]}
      )

    :ok = Event.Bus.subscribe(id, level: :lifecycle)
    Agent.ask(agent, "ship it", sender: sender)
    assert_receive %Event{payload: %Event.TurnParked{}}
    id
  end

  # An agent running a turn, which goes on until it is sent `:release`.
  defp busy_agent(id \\ Fleet.id()) do
    {id, agent} =
      Fleet.start_agent([runner: {AgentRunners, :blocking, [self(), "ok"]}, grace: 10], id)

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

    test "sends the agent the message from the caller, and says its ID" do
      {id, _agent} = Fleet.start_agent(runner: {AgentRunners, :echo, [self(), "ok"]})
      :ok = Event.Bus.subscribe(id)
      {:ok, ask} = Ask.new(id, %{"id" => "m1", "content" => "hi"})

      assert {:ok, %{"message" => %{"id" => "m1"}}} = Command.run(ask, caller())
      assert_receive %Event{payload: %Event.MessageQueued{message: %{sender: sender}}}
      assert Principal.id(sender) == "jon"
      assert_receive {:turn, _messages}

      {:ok, nobody} = Ask.new(Fleet.id("nobody"), %{"content" => "hi"})
      assert {:error, %Error{type: :not_found}} = Command.run(nobody, caller())
    end
  end

  describe "deciding" do
    defp decide(id, decisions), do: Decide.new(id, %{"decisions" => decisions})

    test "reads approvals, with their notes, and rejections, with their reasons" do
      id = Fleet.id()

      assert {:ok, %Decide{decisions: decisions}} =
               decide(id, [
                 %{"id" => "a", "decision" => "approve"},
                 %{"id" => "b", "decision" => "approve", "note" => "Only staging."},
                 %{"id" => "c", "decision" => "reject", "reason" => "Not now."},
                 %{"id" => "d", "decision" => "reject"}
               ])

      assert decisions == %{
               "a" => :approve,
               "b" => {:approve, "Only staging."},
               "c" => {:deny, "Not now."},
               "d" => {:deny, "A person refused this call."}
             }

      for body <- [%{}, %{"decisions" => []}, %{"decisions" => [%{"id" => "a"}]}] do
        assert {:error, %Error{type: :invalid}} = Decide.new(id, body)
      end

      assert {:error, %Error{type: :invalid}} =
               decide(id, [%{"id" => "a", "decision" => "maybe"}])
    end

    test "decides a call the agent waits on, as the caller" do
      id = parked_agent()

      {:ok, decided} =
        decide(id, [%{"id" => "call_1", "decision" => "reject", "reason" => "No."}])

      assert {:ok, %{"decisions" => [%{"id" => "call_1", "decision" => "rejected"}]}} =
               Command.run(decided, caller())

      assert_receive %Event{payload: %Event.CallDecided{call_id: "call_1", by: by}}
      assert Principal.id(by) == "jon"
      assert {:error, %Error{type: :conflict}} = Command.run(decided, caller())
    end

    test "refuses calls the agent does not wait on, or an agent not running" do
      id = parked_agent()

      {:ok, stale} =
        decide(id, [
          %{"id" => "call_9", "decision" => "approve"},
          %{"id" => "call_8", "decision" => "approve"}
        ])

      assert {:error, %Error{type: :conflict, message: message}} = Command.run(stale, caller())
      assert message == "#{id} is not waiting on call_8 and call_9."

      {:ok, nobody} = decide(Fleet.id("nobody"), [%{"id" => "call_1", "decision" => "approve"}])
      assert {:error, %Error{type: :not_found}} = Command.run(nobody, caller())
    end

    test "takes a decision from whoever asked for the turn, and refuses anyone else without a grant to" do
      maria = Principal.new(:channel, "slack/U1", name: "Maria")
      id = parked_agent(maria)
      {:ok, grant} = Grant.new(Prefix.parse!("test/"), [:read, :message])
      {:ok, decided} = decide(id, [%{"id" => "call_1", "decision" => "approve"}])

      assert {:error, %Error{type: :forbidden}} = Command.run(decided, caller("test/", [:read]))

      assert {:ok, _decided} =
               Command.run(decided, Caller.new(principal: maria, grant: grant, host: host()))

      assert_receive %Event{payload: %Event.CallDecided{call_id: "call_1", by: ^maria}}
    end

    test "says so where the agent cannot record the decision" do
      id = parked_agent()
      :ok = EventLog.usurp(id)
      {:ok, decided} = decide(id, [%{"id" => "call_1", "decision" => "approve"}])

      assert {:error, %Error{type: :unavailable}} = Command.run(decided, caller())
    end
  end

  describe "cancelling" do
    test "stops what the agent is doing, and is recorded" do
      {id, _turn} = busy_agent()

      assert {:ok, %{"cancelled" => [text]}} = Command.run(%Cancel{agent: id}, caller())
      assert text == to_string(id)
      assert_receive %Event{payload: %Event.TurnInterrupted{}}
      assert Audit.about("agents/#{id}") == [{"agent.cancelled", @jon}]

      assert {:error, %Error{type: :not_found}} =
               Command.run(%Cancel{agent: Fleet.id("nobody")}, caller())
    end

    test "leaves an agent taking no turn as it is, and records nothing" do
      {id, _agent} = Fleet.start_agent()

      assert {:ok, change} = Command.plan(%Cancel{agent: id}, caller())
      assert Command.preview(change) == %{"cancelling" => []}
      assert {:ok, %{"cancelled" => []}} = Command.make(change, caller())
      assert Audit.about("agents/#{id}") == []
    end

    test "under a prefix stops each agent taking a turn, recorded as one change" do
      org = "cancel-#{System.unique_integer([:positive])}"
      prefix = Prefix.new!(org: org)
      {busy, _turn} = busy_agent(AgentID.new!("busy", org: org))
      {other, _turn} = busy_agent(AgentID.new!("other", org: org))
      {idle, _agent} = Fleet.start_agent([], AgentID.new!("idle", org: org))

      assert {:ok, change} = Command.plan(%CancelAgents{prefix: prefix}, caller("#{org}/"))
      assert Command.preview(change) == %{"cancelling" => [to_string(busy), to_string(other)]}

      assert {:ok, %{"cancelled" => [_, _]}} = Command.make(change, caller("#{org}/"))
      assert Audit.about("agents/#{idle}") == []

      entries =
        for %{"subject" => "agents/" <> agent} = event <- Wardrik.Test.Audit.all(),
            agent in [to_string(busy), to_string(other)],
            do: event

      assert [%{"traceparent" => trace}, %{"traceparent" => trace}] = entries
      assert Enum.all?(entries, &(&1["data"]["under"] == "#{org}/"))
    end

    test "under a prefix outside the caller's scope reaches nothing" do
      assert {:error, %Error{type: :not_found}} =
               Command.plan(%CancelAgents{prefix: Prefix.new!(org: "other")}, caller())

      assert {:error, %Error{type: :forbidden}} =
               Command.plan(
                 %CancelAgents{prefix: Prefix.parse!("test/")},
                 caller("test/", [:read])
               )
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
               Command.run(
                 %Define{agent: id, definition: %{}},
                 Caller.new(principal: nil, grant: grant, host: host())
               )

      %{user_state: state} = :sys.get_state(Wardrik.Fleet.whereis(id))
      assert [%Wardrik.Hook{name: "ceiling"}] = Keyword.fetch!(state.scope_opts, :hooks)
    end
  end

  describe "forgetting" do
    test "removes the agent with its definition, then finds nothing" do
      id = defined_id()
      {:created, _snapshot} = Command.run(%Define{agent: id, definition: %{}}, caller())

      assert {:ok, change} = Command.plan(%Forget{agent: id}, caller())
      assert Command.preview(change) == %{"forgetting" => [to_string(id)], "keeping" => []}

      assert {:ok, %{"forgotten" => [_id], "kept" => [], "failed" => []}} =
               Command.make(change, caller())

      assert Wardrik.Fleet.lookup(id) == nil
      assert {:error, %Error{type: :not_found}} = Query.run(%ReadDefinition{agent: id}, caller())
      assert {:error, %Error{type: :not_found}} = Command.run(%Forget{agent: id}, caller())
    end

    test "removes an agent the host kept no definition for, unless the host keeps it" do
      {id, _agent} = Fleet.start_agent()
      assert {:ok, %{"forgotten" => [_id]}} = Command.run(%Forget{agent: id}, caller())
      assert Wardrik.Fleet.lookup(id) == nil

      {owned, _agent} = Fleet.start_agent([], Fleet.id("kept-owned"))

      assert {:error, %Error{type: :conflict, message: message}} =
               Command.plan(%Forget{agent: owned}, caller())

      assert message == "#{owned} belongs to a file."
      assert Wardrik.Fleet.lookup(owned)
    end

    test "under a prefix removes what the host lets go, says why it keeps the rest" do
      org = "forget-#{System.unique_integer([:positive])}"
      prefix = Prefix.new!(org: org)
      {gone, _agent} = Fleet.start_agent([], AgentID.new!("gone", org: org))
      {owned, _agent} = Fleet.start_agent([], AgentID.new!("kept-owned", org: org))
      on_exit(fn -> Wardrik.Fleet.forget(owned) end)

      assert {:ok, change} = Command.plan(%ForgetAgents{prefix: prefix}, caller("#{org}/"))

      assert Command.preview(change) == %{
               "forgetting" => [to_string(gone)],
               "keeping" => [%{"id" => to_string(owned), "why" => "#{owned} belongs to a file."}]
             }

      assert {:ok, %{"forgotten" => [_gone], "kept" => [_owned], "failed" => []}} =
               Command.make(change, caller("#{org}/"))

      assert Wardrik.Fleet.lookup(gone) == nil
      assert Wardrik.Fleet.lookup(owned)

      assert [%{"data" => %{"under" => under}}] =
               for(e <- Wardrik.Test.Audit.all(), e["subject"] == "agents/#{gone}", do: e)

      assert under == "#{org}/"

      assert {:error, %Error{type: :conflict}} =
               Command.plan(%ForgetAgents{prefix: prefix}, caller("#{org}/"))

      assert {:error, %Error{type: :not_found}} =
               Command.plan(%ForgetAgents{prefix: Prefix.new!(org: "#{org}-none")}, caller())
    end
  end

  describe "listing" do
    test "answers every agent under the prefix, and refuses a caller who may not read them" do
      {id, _agent} = Fleet.start_agent()

      assert {:ok, %{"agents" => agents}} =
               Query.run(%ListAgents{prefix: Prefix.parse!("test/")}, caller())

      assert Enum.any?(agents, &(&1["id"] == to_string(id)))

      assert {:error, %Error{type: :forbidden}} =
               Query.run(%ListAgents{prefix: Prefix.parse!("test/")}, caller("test/", [:message]))
    end

    test "answers each call waiting on a person, with its agent" do
      id = parked_agent()
      assert Fleet.await_update(fn -> Wardrik.Fleet.lookup(id).status == :parked end)

      assert {:ok, %{"interrupts" => interrupts}} =
               Query.run(%ListParked{prefix: Prefix.of(id)}, caller())

      assert [%{"id" => "call_1", "agent" => %{"id" => text}}] = interrupts
      assert text == to_string(id)
    end
  end

  describe "triggers" do
    setup do
      id = defined_id("triggered")
      {:created, _snapshot} = Command.run(%Define{agent: id, definition: %{}}, caller())
      %{id: id}
    end

    test "are set, changed and removed, and each change recorded", %{id: id} do
      fields = %{"every" => "1h", "prompt" => "Look."}

      assert {:created, %{"trigger" => %{"name" => "sweep"}}} =
               Command.run(%SetTrigger{agent: id, name: "sweep", fields: fields}, caller())

      assert {:ok, %{"trigger" => %{"every" => "2h"}}} =
               Command.run(
                 %SetTrigger{agent: id, name: "sweep", fields: %{fields | "every" => "2h"}},
                 caller()
               )

      assert {:ok, nil} = Command.run(%RemoveTrigger{agent: id, name: "sweep"}, caller())

      assert {:error, %Error{type: :not_found, message: message}} =
               Command.run(%RemoveTrigger{agent: id, name: "sweep"}, caller())

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
               Command.run(
                 %SetTrigger{agent: id, name: "sweep", fields: %{"refuse" => "no time"}},
                 caller()
               )

      assert {:error, %Error{type: :not_found, message: message}} =
               Command.run(
                 %SetTrigger{agent: Fleet.id("nobody"), name: "s", fields: %{}},
                 caller()
               )

      assert message =~ "has no definition kept."

      owned = Fleet.id("kept-owned")

      assert {:error, %Error{type: :conflict}} =
               Command.run(%SetTrigger{agent: owned, name: "s", fields: %{}}, caller())

      assert {:error, %Error{type: :conflict}} =
               Command.run(%RemoveTrigger{agent: owned, name: "s"}, caller())
    end
  end

  describe "stopping" do
    test "puts an agent to sleep with its conversation, and leaves one asleep be" do
      {id, _agent} = Fleet.start_agent()

      assert {:ok, %{"stopped" => [text]}} = Command.run(%Stop{agent: id}, caller())
      assert text == to_string(id)
      assert %{asleep: true} = Wardrik.Fleet.lookup(id)

      assert {:ok, %{"stopped" => []}} = Command.run(%Stop{agent: id}, caller())
      assert Audit.about("agents/#{id}") == [{"agent.stopped", @jon}]

      assert {:error, %Error{type: :not_found}} =
               Command.run(%Stop{agent: Fleet.id("nobody")}, caller())
    end
  end

  describe "spawning" do
    test "leaves an agent running as it is, and wakes one asleep" do
      {id, _agent} = Fleet.start_agent()

      assert {:ok, %{"from" => "running"}} = Command.run(%Spawn{agent: id}, caller())
      :ok = Wardrik.Fleet.stop(id)

      assert {:ok, change} = Command.plan(%Spawn{agent: id}, caller())

      assert Command.preview(change) == %{
               "spawning" => %{"agent" => to_string(id), "from" => "store"}
             }

      assert {:ok, %{"from" => "store", "agent" => %{"asleep" => false}}} =
               Command.make(change, caller())

      assert Audit.about("agents/#{id}") == [{"agent.spawned", @jon}]
    end

    test "starts an agent on its definition, or defines one nothing defines" do
      id = defined_id()

      {:ok, _vsn} =
        WardrikStore.put(:operations_test_definitions, to_string(id), %{"model" => "openai:gpt-5"})

      assert {:ok, %{"from" => "definition"}} = Command.run(%Spawn{agent: id}, caller())
      assert Agent.status(id).model == "openai:gpt-5"

      fresh = defined_id("fresh")
      assert {:ok, %{"from" => "new"}} = Command.run(%Spawn{agent: fresh}, caller())
      assert {:ok, %{"model" => "openai:gpt-5"}} = Kept.get(fresh)

      owned = defined_id("fresh-owned")

      assert {:error, %Error{type: :conflict}} = Command.run(%Spawn{agent: owned}, caller())
    end

    test "finds nothing to start where nothing defines it and the host creates none" do
      none = caller("test/", Grant.actions(), Host.new())

      assert {:error, %Error{type: :not_found}} =
               Command.run(%Spawn{agent: Fleet.id("nobody")}, none)
    end

    test "on a node is the deployment's to choose" do
      id = defined_id("placed")
      root = root()

      assert {:ok, %{"from" => "new", "agent" => %{"node" => node}}} =
               Command.run(%SpawnOn{agent: id, node: node()}, root)

      assert node == to_string(node())

      assert {:error, %Error{type: :forbidden}} =
               Command.plan(%SpawnOn{agent: id, node: node()}, caller())

      assert {:error, %Error{type: :invalid}} =
               Command.plan(%SpawnOn{agent: id, node: :nowhere@nohost}, root)
    end
  end

  describe "moving" do
    test "leaves an agent on its node be, interrupting nothing" do
      root = root()
      {id, _turn} = busy_agent()

      assert {:ok, change} = Command.plan(%Move{agent: id, node: node()}, root)

      assert Command.preview(change) == %{
               "moving" => %{
                 "agent" => to_string(id),
                 "from" => to_string(node()),
                 "to" => to_string(node())
               }
             }

      assert {:ok, %{"agent" => _agent}} = Command.make(change, root)
      assert Audit.about("agents/#{id}") == []

      assert {:error, %Error{type: :forbidden}} =
               Command.plan(%Move{agent: id, node: node()}, caller())

      assert {:error, %Error{type: :not_found}} =
               Command.plan(%Move{agent: Fleet.id("nobody"), node: node()}, root)
    end
  end

  describe "a host without a definitions module, or one that only reads" do
    test "defines, keeps and triggers nothing, and forgets an agent with no definition" do
      {id, _agent} = Fleet.start_agent()

      for module <- [Wardrik.Definition.None, Reading] do
        caller = caller("test/", Grant.actions(), host(module))

        assert {:error, %Error{type: :unsupported}} =
                 Query.run(%ReadDefinition{agent: id}, caller)

        assert {:error, %Error{type: :unsupported}} =
                 Command.run(%SetTrigger{agent: id, name: "s", fields: %{}}, caller)

        assert {:error, %Error{type: :unsupported}} =
                 Command.run(%RemoveTrigger{agent: id, name: "s"}, caller)
      end

      none = caller("test/", Grant.actions(), Host.new())

      assert {:error, %Error{type: :unsupported}} =
               Command.run(%Define{agent: id, definition: %{}}, none)

      assert Wardrik.Fleet.lookup(id)

      assert {:ok, %{"forgotten" => [_id]}} = Command.run(%Forget{agent: id}, none)
      assert Wardrik.Fleet.lookup(id) == nil
    end
  end
end
