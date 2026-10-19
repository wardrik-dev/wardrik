defmodule Wardrik.TalkingTest do
  # The audit is one for the node, which these tests read.
  use ExUnit.Case, async: false

  import Wardrik.Test, only: [store: 0]

  alias Wardrik.Agent
  alias Wardrik.Agent.Message
  alias Wardrik.Agent.Snapshot
  alias Wardrik.AgentID
  alias Wardrik.Error
  alias Wardrik.Event
  alias Wardrik.Event.Log
  alias Wardrik.Fleet.Member
  alias Wardrik.Principal
  alias Wardrik.Resource
  alias Wardrik.Role
  alias Wardrik.Scope
  alias Wardrik.Test.AgentRunners
  alias Wardrik.Test.Audit
  alias Wardrik.Test.EventLog
  alias Wardrik.Test.Fleet
  alias Wardrik.Test.Script
  alias Wardrik.Token

  @jon %{"type" => "user", "id" => "jon", "name" => "Jon"}

  defp scope(pattern \\ "test/agent/*", roles \\ [:owner]) do
    token = %Token{principal: jon(), scope: [Role.bind(roles, [Resource.parse!(pattern)])]}
    Scope.new(Wardrik.Test.host(), token)
  end

  defp jon, do: Principal.new(:user, "jon", name: "Jon")

  defp parked_agent(sender \\ nil) do
    {id, agent} =
      Fleet.start_agent(
        config:
          Script.new({AgentRunners, :parking, [self(), "call_1"]},
            resume:
              {AgentRunners, :resuming,
               [self(), {:ok, [Wardrik.Conversation.Assistant.new("shipped")]}]}
          )
      )

    :ok = Event.Bus.subscribe(id, level: :lifecycle)
    Agent.ask(agent, "ship it", sender: sender)
    assert_receive %Event{payload: %Event.TurnParked{}}
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

    # The runner hears of the turn before the agent's status reaches the
    # fleet, which is what a cancel reads.
    Fleet.await_update(fn ->
      Wardrik.Fleet.lookup(id, host: Wardrik.Test.host()).status != :idle
    end)

    {id, turn}
  end

  describe "a read" do
    test "answers what the scope's token reaches and allows" do
      {id, _agent} = Fleet.start_agent()

      assert {:ok, %Snapshot{agent: ^id}} =
               Wardrik.agent_read(scope("test/agent/*", [:reader]), id)
    end

    test "finds nothing its token does not reach, and refuses what it does not allow" do
      {id, _agent} = Fleet.start_agent()

      assert {:error, %Error{type: :not_found}} =
               Wardrik.agent_read(scope("other/agent/*", [:reader]), id)

      assert {:error, %Error{type: :forbidden, message: message}} =
               Wardrik.agent_read(scope("test/agent/*", [:messenger]), id)

      assert message == "This token does not allow agent.read on #{id}."
      assert {:error, %Error{type: :not_found}} = Wardrik.agent_read(scope(), Fleet.id())
    end
  end

  describe "a change" do
    test "is recorded once it is made, as the scope's principal" do
      {id, _agent} = Fleet.start_agent()

      assert {:ok, %Snapshot{}} = Wardrik.agent_clear(scope(), id)
      assert Audit.about(id) == [{"agent.cleared", @jon}]
    end

    test "is made only where the scope's token allows it, and one that fails is not recorded" do
      {id, _agent} = Fleet.start_agent()

      assert {:error, %Error{type: :forbidden}} =
               Wardrik.agent_clear(scope("test/agent/*", [:reader]), id)

      nobody = Fleet.id("nobody")
      assert {:error, %Error{type: :not_found}} = Wardrik.agent_clear(scope(), nobody)
      assert Audit.about(id) == []
      assert Audit.about(nobody) == []
    end

    test "waits while a turn runs, to clear" do
      {id, turn} = busy_agent()

      assert {:error, %Error{type: :conflict}} = Wardrik.agent_clear(scope(), id)
      send(turn, :release)
      assert_receive %Event{payload: %Event.TurnFinished{}}

      assert {:ok, %Snapshot{}} = Wardrik.agent_clear(scope(), id)
    end
  end

  test "a page of events after a sequence, and where the log now starts" do
    {id, agent} = Fleet.start_agent(config: Script.new({AgentRunners, :echo, [self(), "ok"]}))
    :ok = Event.Bus.subscribe(id, level: :lifecycle)
    Agent.ask(agent, "hi")
    assert_receive %Event{payload: %Event.TurnFinished{}}

    assert {:ok, [%Log.Entry{sequence: 1, follows: 0}, %Log.Entry{sequence: 2}]} =
             Wardrik.agent_events(scope(), id, limit: 2)

    :ok = Log.trim(store(), id, through: 2, before: DateTime.add(DateTime.utc_now(), 1, :day))

    assert {:error, %Error{type: :gap, details: %{"oldest" => 3}}} =
             Wardrik.agent_events(scope(), id, limit: 2)
  end

  describe "an authorization" do
    test "answers where a person authorizes the call, to a scope that may decide it" do
      link = %{url: "https://github.com/login/device", code: "WDJB-MJHT"}

      {id, agent} =
        Fleet.start_agent(
          config: Script.new({AgentRunners, :connecting, [self(), "call_1", link]})
        )

      :ok = Event.Bus.subscribe(id, level: :lifecycle)
      Agent.ask(agent, "open an issue")
      assert_receive %Event{payload: %Event.TurnParked{}}

      assert {:ok, ^link} = Wardrik.agent_authorization_read(scope(), id, "call_1")

      assert {:error, %Error{type: :not_found}} =
               Wardrik.agent_authorization_read(scope(), id, "nope")

      assert {:error, %Error{type: :forbidden}} =
               Wardrik.agent_authorization_read(scope("test/agent/*", [:reader]), id, "call_1")
    end

    test "is none for a call that waits on a decision, or an agent not running" do
      id = parked_agent()

      assert {:error, %Error{type: :not_found, message: "call_1 waits on no authorization."}} =
               Wardrik.agent_authorization_read(scope(), id, "call_1")

      assert {:error, %Error{type: :not_found}} =
               Wardrik.agent_authorization_read(scope(), Fleet.id("nobody"), "call_1")
    end
  end

  describe "asking" do
    test "sends the agent the message from the scope, and says where its log stood" do
      {id, _agent} = Fleet.start_agent(config: Script.new({AgentRunners, :echo, [self(), "ok"]}))
      :ok = Event.Bus.subscribe(id)

      assert {:ok, %Message{id: "m1", sequence: sequence}} =
               Wardrik.agent_ask(scope(), id, "hi", id: "m1")

      assert is_integer(sequence)
      assert_receive %Event{payload: %Event.MessageQueued{message: %{sender: sender}}}
      assert Principal.id(sender) == "jon"
      assert_receive {:turn, _messages}

      assert {:error, %Error{type: :not_found}} =
               Wardrik.agent_ask(scope(), Fleet.id("nobody"), "hi")
    end

    test "needs text, and an id that is text" do
      {id, _agent} = Fleet.start_agent()

      assert {:error, %Error{type: :invalid}} = Wardrik.agent_ask(scope(), id, "")
      assert {:error, %Error{type: :invalid}} = Wardrik.agent_ask(scope(), id, "hi", id: "")
    end
  end

  describe "deciding" do
    test "decides a call the agent waits on, as the scope's principal" do
      id = parked_agent()

      assert {:ok, %{"call_1" => {:deny, "No."}}} =
               Wardrik.agent_deny(scope(), id, "call_1", reason: "No.")

      assert_receive %Event{payload: %Event.CallDecided{call_id: "call_1", by: by}}
      assert Principal.id(by) == "jon"

      assert {:error, %Error{type: :conflict}} = Wardrik.agent_approve(scope(), id, "call_1")
    end

    test "refuses calls the agent does not wait on, or an agent not running" do
      id = parked_agent()

      assert {:error, %Error{type: :conflict, message: message}} =
               Wardrik.agent_approve(scope(), id, ["call_9", "call_8"])

      assert message == "#{id} is not waiting on call_8 and call_9."

      assert {:error, %Error{type: :not_found}} =
               Wardrik.agent_approve(scope(), Fleet.id("nobody"), "call_1")
    end

    test "takes a decision from whoever asked for the turn, and refuses anyone else without a token allowing it" do
      maria = Principal.new(:channel, "slack/U1", name: "Maria")
      id = parked_agent(maria)

      token = %Token{
        principal: maria,
        scope: [Role.bind([:reader, :messenger], [Resource.parse!("test/agent/*")])]
      }

      assert {:error, %Error{type: :forbidden}} =
               Wardrik.agent_approve(scope("test/agent/*", [:reader]), id, "call_1")

      asker = Scope.new(Wardrik.Test.host(), token)
      assert {:ok, _decided} = Wardrik.agent_approve(asker, id, "call_1")
      assert_receive %Event{payload: %Event.CallDecided{call_id: "call_1", by: ^maria}}
    end

    test "says so where the agent cannot record the decision" do
      id = parked_agent()
      :ok = EventLog.usurp(id)

      assert {:error, %Error{type: :unavailable}} = Wardrik.agent_approve(scope(), id, "call_1")
    end
  end

  describe "listing" do
    test "answers every agent under the prefix, and refuses a scope that may not read them" do
      {id, _agent} = Fleet.start_agent()

      assert {:ok, members} = Wardrik.agents_list(scope(), Resource.parse!("test/agent/*"))
      assert %Member{} = Enum.find(members, &(&1.id == id))

      assert {:error, %Error{type: :forbidden}} =
               Wardrik.agents_list(
                 scope("test/agent/*", [:messenger]),
                 Resource.parse!("test/agent/*")
               )
    end

    test "answers each call waiting on a person, with its agent" do
      id = parked_agent()

      assert Fleet.await_update(fn ->
               Wardrik.Fleet.lookup(id, host: Wardrik.Test.host()).status == :parked
             end)

      assert {:ok, [{^id, {%{id: "call_1"}, _prompt}}]} =
               Wardrik.agents_parked(scope(), Wardrik.AgentID.resource(id))
    end
  end

  describe "the tool calls an agent runs" do
    # A call to a tool that waits until it is stopped, made as `agent`'s
    # own, in a process of its own that stopping it ends.
    defp hanging(agent) do
      test = self()

      hang =
        Wardrik.Tool.new!(
          name: "hang",
          description: "Waits.",
          run: fn _input, _context ->
            send(test, :started)
            receive do: (:never -> {:ok, %{}})
          end
        )

      run = Wardrik.Test.run(id: agent, tools: [hang])
      spawn(fn -> Wardrik.Test.call(run, "hang", %{}, id: "call_1") end)
      assert_receive :started
    end

    test "are listed, and one is stopped, as the scope's principal" do
      {id, _agent} = Fleet.start_agent()
      hanging(id)

      assert {:ok, [%{call_id: "call_1", name: "hang", elapsed_ms: elapsed}]} =
               Wardrik.agent_calls(scope("test/agent/*", [:reader]), id)

      assert is_integer(elapsed)

      assert {:error, %Error{type: :forbidden}} =
               Wardrik.agent_call_kill(scope("test/agent/*", [:reader]), id, "call_1")

      assert :ok = Wardrik.agent_call_kill(scope(), id, "call_1")
      assert Audit.about(id) == [{"call.killed", @jon}]

      assert {:error, %Error{type: :not_found}} =
               Wardrik.agent_call_kill(scope(), id, "call_1")
    end

    test "are none of an agent asleep, or of none" do
      {id, _agent} = Fleet.start_agent()
      :ok = Wardrik.Fleet.stop(id)

      assert {:error, %Error{type: :not_found}} = Wardrik.agent_calls(scope(), id)
      assert {:error, %Error{type: :not_found}} = Wardrik.agent_calls(scope(), Fleet.id())

      assert {:error, %Error{type: :not_found}} =
               Wardrik.agent_call_kill(scope(), AgentID.parse!("other/nobody"), "call_1")
    end
  end
end
