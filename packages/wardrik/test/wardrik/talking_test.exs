defmodule Wardrik.TalkingTest do
  # The audit is one for the node, which these tests read.
  use ExUnit.Case, async: false

  import Wardrik.Test, only: [store: 0]

  alias ReqLLM.Context
  alias Wardrik.Agent
  alias Wardrik.Agent.Message
  alias Wardrik.Agent.Snapshot
  alias Wardrik.AgentID
  alias Wardrik.AgentID.Prefix
  alias Wardrik.Error
  alias Wardrik.Event
  alias Wardrik.Event.Log
  alias Wardrik.Fleet.Member
  alias Wardrik.Grant
  alias Wardrik.Principal
  alias Wardrik.Session
  alias Wardrik.Test.AgentRunners
  alias Wardrik.Test.Audit
  alias Wardrik.Test.EventLog
  alias Wardrik.Test.Fleet

  @jon %{"type" => "user", "id" => "jon", "name" => "Jon"}

  defp session(scope \\ "test/", can \\ Grant.actions()) do
    {:ok, grant} = Grant.new(Prefix.parse!(scope), can)
    Session.new(host: Wardrik.Test.host(), principal: jon(), grant: grant)
  end

  defp jon, do: Principal.new(:user, "jon", name: "Jon")

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

    # The runner hears of the turn before the agent's status reaches the
    # fleet, which is what a cancel reads.
    Fleet.await_update(fn ->
      Wardrik.Fleet.lookup(id, host: Wardrik.Test.host()).status != :idle
    end)

    {id, turn}
  end

  describe "a read" do
    test "answers what the session's grant reaches and allows" do
      {id, _agent} = Fleet.start_agent()

      assert {:ok, %Snapshot{agent: ^id}} = Wardrik.agent_read(session("test/", [:read]), id)
    end

    test "finds nothing outside the session's scope, and refuses what its grant does not allow" do
      {id, _agent} = Fleet.start_agent()

      assert {:error, %Error{type: :not_found}} =
               Wardrik.agent_read(session("other/", [:read]), id)

      assert {:error, %Error{type: :forbidden, message: message}} =
               Wardrik.agent_read(session("test/", [:message]), id)

      assert message == "This caller may not read #{id}."
      assert {:error, %Error{type: :not_found}} = Wardrik.agent_read(session(), Fleet.id())
    end
  end

  describe "a change" do
    test "is recorded once it is made, as the session's principal" do
      {id, _agent} = Fleet.start_agent()

      assert {:ok, %Snapshot{}} = Wardrik.agent_clear(session(), id)
      assert Audit.about("agents/#{id}") == [{"agent.cleared", @jon}]
    end

    test "is made only where the session's grant allows it, and one that fails is not recorded" do
      {id, _agent} = Fleet.start_agent()

      assert {:error, %Error{type: :forbidden}} =
               Wardrik.agent_clear(session("test/", [:read]), id)

      nobody = Fleet.id("nobody")
      assert {:error, %Error{type: :not_found}} = Wardrik.agent_clear(session(), nobody)
      assert Audit.about("agents/#{id}") == []
      assert Audit.about("agents/#{nobody}") == []
    end

    test "waits while a turn runs, to clear" do
      {id, turn} = busy_agent()

      assert {:error, %Error{type: :conflict}} = Wardrik.agent_clear(session(), id)
      send(turn, :release)
      assert_receive %Event{payload: %Event.TurnFinished{}}

      assert {:ok, %Snapshot{}} = Wardrik.agent_clear(session(), id)
    end
  end

  test "a page of events after a sequence, and where the log now starts" do
    {id, agent} = Fleet.start_agent(runner: {AgentRunners, :echo, [self(), "ok"]})
    :ok = Event.Bus.subscribe(id, level: :lifecycle)
    Agent.ask(agent, "hi")
    assert_receive %Event{payload: %Event.TurnFinished{}}

    assert {:ok, [%Log.Entry{sequence: 1, follows: 0}, %Log.Entry{sequence: 2}]} =
             Wardrik.agent_events(session(), id, limit: 2)

    :ok = Log.trim(store(), id, through: 2, before: DateTime.add(DateTime.utc_now(), 1, :day))

    assert {:error, %Error{type: :gap, details: %{"oldest" => 3}}} =
             Wardrik.agent_events(session(), id, limit: 2)
  end

  describe "an authorization" do
    test "answers where a person authorizes the call, to a session that may decide it" do
      link = %{url: "https://github.com/login/device", code: "WDJB-MJHT"}

      {id, agent} =
        Fleet.start_agent(runner: {AgentRunners, :connecting, [self(), "call_1", link]})

      :ok = Event.Bus.subscribe(id, level: :lifecycle)
      Agent.ask(agent, "open an issue")
      assert_receive %Event{payload: %Event.TurnParked{}}

      assert {:ok, ^link} = Wardrik.agent_authorization_read(session(), id, "call_1")

      assert {:error, %Error{type: :not_found}} =
               Wardrik.agent_authorization_read(session(), id, "nope")

      assert {:error, %Error{type: :forbidden}} =
               Wardrik.agent_authorization_read(session("test/", [:read]), id, "call_1")
    end

    test "is none for a call that waits on a decision, or an agent not running" do
      id = parked_agent()

      assert {:error, %Error{type: :not_found, message: "call_1 waits on no authorization."}} =
               Wardrik.agent_authorization_read(session(), id, "call_1")

      assert {:error, %Error{type: :not_found}} =
               Wardrik.agent_authorization_read(session(), Fleet.id("nobody"), "call_1")
    end
  end

  describe "asking" do
    test "sends the agent the message from the session, and says where its log stood" do
      {id, _agent} = Fleet.start_agent(runner: {AgentRunners, :echo, [self(), "ok"]})
      :ok = Event.Bus.subscribe(id)

      assert {:ok, %Message{id: "m1", sequence: sequence}} =
               Wardrik.agent_ask(session(), id, "hi", id: "m1")

      assert is_integer(sequence)
      assert_receive %Event{payload: %Event.MessageQueued{message: %{sender: sender}}}
      assert Principal.id(sender) == "jon"
      assert_receive {:turn, _messages}

      assert {:error, %Error{type: :not_found}} =
               Wardrik.agent_ask(session(), Fleet.id("nobody"), "hi")
    end

    test "needs text, and an id that is text" do
      {id, _agent} = Fleet.start_agent()

      assert {:error, %Error{type: :invalid}} = Wardrik.agent_ask(session(), id, "")
      assert {:error, %Error{type: :invalid}} = Wardrik.agent_ask(session(), id, "hi", id: "")
    end
  end

  describe "deciding" do
    test "decides a call the agent waits on, as the session's principal" do
      id = parked_agent()

      assert {:ok, %{"call_1" => {:deny, "No."}}} =
               Wardrik.agent_deny(session(), id, "call_1", reason: "No.")

      assert_receive %Event{payload: %Event.CallDecided{call_id: "call_1", by: by}}
      assert Principal.id(by) == "jon"

      assert {:error, %Error{type: :conflict}} = Wardrik.agent_approve(session(), id, "call_1")
    end

    test "refuses calls the agent does not wait on, or an agent not running" do
      id = parked_agent()

      assert {:error, %Error{type: :conflict, message: message}} =
               Wardrik.agent_approve(session(), id, ["call_9", "call_8"])

      assert message == "#{id} is not waiting on call_8 and call_9."

      assert {:error, %Error{type: :not_found}} =
               Wardrik.agent_approve(session(), Fleet.id("nobody"), "call_1")
    end

    test "takes a decision from whoever asked for the turn, and refuses anyone else without a grant to" do
      maria = Principal.new(:channel, "slack/U1", name: "Maria")
      id = parked_agent(maria)
      {:ok, grant} = Grant.new(Prefix.parse!("test/"), [:read, :message])

      assert {:error, %Error{type: :forbidden}} =
               Wardrik.agent_approve(session("test/", [:read]), id, "call_1")

      asker = Session.new(host: Wardrik.Test.host(), principal: maria, grant: grant)
      assert {:ok, _decided} = Wardrik.agent_approve(asker, id, "call_1")
      assert_receive %Event{payload: %Event.CallDecided{call_id: "call_1", by: ^maria}}
    end

    test "says so where the agent cannot record the decision" do
      id = parked_agent()
      :ok = EventLog.usurp(id)

      assert {:error, %Error{type: :unavailable}} = Wardrik.agent_approve(session(), id, "call_1")
    end
  end

  describe "listing" do
    test "answers every agent under the prefix, and refuses a session that may not read them" do
      {id, _agent} = Fleet.start_agent()

      assert {:ok, members} = Wardrik.agents_list(session(), Prefix.parse!("test/"))
      assert %Member{} = Enum.find(members, &(&1.id == id))

      assert {:error, %Error{type: :forbidden}} =
               Wardrik.agents_list(session("test/", [:message]), Prefix.parse!("test/"))
    end

    test "answers each call waiting on a person, with its agent" do
      id = parked_agent()

      assert Fleet.await_update(fn ->
               Wardrik.Fleet.lookup(id, host: Wardrik.Test.host()).status == :parked
             end)

      assert {:ok, [{^id, {%{id: "call_1"}, _prompt}}]} =
               Wardrik.agents_parked(session(), Prefix.of(id))
    end
  end

  describe "the tool calls an agent runs" do
    # A call to a tool that waits until it is stopped, made as `agent`'s
    # own, in a process of its own that stopping it ends.
    defp hanging(agent) do
      test = self()

      hang =
        ReqLLM.Tool.new!(
          name: "hang",
          description: "Waits.",
          callback: fn _input ->
            send(test, :started)
            receive do: (:never -> {:ok, %{}})
          end
        )

      run = Wardrik.Test.run(id: agent, tools: [hang])
      spawn(fn -> Wardrik.Test.call(run, "hang", %{}, id: "call_1") end)
      assert_receive :started
    end

    test "are listed, and one is stopped, as the session's principal" do
      {id, _agent} = Fleet.start_agent()
      hanging(id)

      assert {:ok, [%{call_id: "call_1", name: "hang", elapsed_ms: elapsed}]} =
               Wardrik.agent_calls(session("test/", [:read]), id)

      assert is_integer(elapsed)

      assert {:error, %Error{type: :forbidden}} =
               Wardrik.agent_call_kill(session("test/", [:read]), id, "call_1")

      assert :ok = Wardrik.agent_call_kill(session(), id, "call_1")
      assert Audit.about("agents/#{id}") == [{"call.killed", @jon}]

      assert {:error, %Error{type: :not_found}} =
               Wardrik.agent_call_kill(session(), id, "call_1")
    end

    test "are none of an agent asleep, or of none" do
      {id, _agent} = Fleet.start_agent()
      :ok = Wardrik.Fleet.stop(id)

      assert {:error, %Error{type: :not_found}} = Wardrik.agent_calls(session(), id)
      assert {:error, %Error{type: :not_found}} = Wardrik.agent_calls(session(), Fleet.id())

      assert {:error, %Error{type: :not_found}} =
               Wardrik.agent_call_kill(session(), AgentID.parse!("other/nobody"), "call_1")
    end
  end
end
