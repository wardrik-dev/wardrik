defmodule Wardrik.Agent.StateTest do
  use ExUnit.Case, async: true

  alias Wardrik.Agent.Activity
  alias Wardrik.Agent.Message
  alias Wardrik.Agent.State
  alias Wardrik.Agent.State.Due
  alias Wardrik.Agent.State.Running
  alias Wardrik.Agent.State.Stored
  alias Wardrik.Agent.State.View
  alias Wardrik.Agent.State.Waiting
  alias Wardrik.Conversation
  alias Wardrik.Conversation.Assistant
  alias Wardrik.Conversation.Text
  alias Wardrik.Conversation.ToolResult
  alias Wardrik.Conversation.User
  alias Wardrik.Event
  alias Wardrik.LLM.Config
  alias Wardrik.LLM.Turn
  alias Wardrik.Run

  defp state, do: State.new([config: Config.new()], Wardrik.AgentID.parse!("acme/@jon/assistant"))

  defp run,
    do: Run.root(Config.new(), Wardrik.AgentID.parse!("acme/@jon/assistant"), name: "turn")

  # A task nobody runs. The state never touches the process, only its ref.
  defp task, do: %Task{pid: self(), ref: make_ref(), owner: self(), mfa: {__MODULE__, :none, 0}}

  defp running(state \\ state()) do
    State.started(state, task(), run(), Conversation.new(), System.monotonic_time())
  end

  defp parked_turn do
    call = %{id: "call_1", name: "deploy", arguments: %{}}

    %Turn{
      context: Conversation.new(),
      answer: Wardrik.Test.LLM.answer(%Assistant{parts: []}, :tool_calls),
      calls: [Wardrik.Test.AgentRunners.waiting(call, "Really?")],
      remaining: 5,
      revision: Wardrik.Hook.revision([]),
      state: :waiting
    }
  end

  defp checkpoint do
    %Turn{
      context: Conversation.new(),
      answer: Wardrik.Test.LLM.answer(%Assistant{parts: []}, :tool_calls),
      remaining: 5
    }
  end

  defp waiting do
    {state, _effects} = running() |> State.parked(parked_turn())
    state
  end

  defp queued(state, n),
    do: Enum.reduce(1..n, state, &elem(State.queue(&2, Message.new("m#{&1}")), 0))

  defp stopping do
    {state, _effects} = State.interrupt(running())
    State.arm(state, make_ref(), 0)
  end

  describe "the mode" do
    test "a fresh agent is idle with nothing queued" do
      assert %{state: :idle, pending: 0} = View.status(state())
    end

    test "each mode reports itself" do
      assert View.status(running()).state == :running
      assert View.status(waiting()).state == :parked
    end

    test "starting a turn replaces idle rather than sitting beside it" do
      assert %State{mode: %Running{}} = running()
    end

    test "parking replaces the running turn, so neither outlives the other" do
      assert %State{mode: %Waiting{}} = waiting()
    end

    test "settling anything returns to idle" do
      {settled, _effects} = State.settled(running(), [], [])
      {failed, _effects} = State.failed(running(), :nope)
      {abandoned, _effects} = State.interrupt(waiting())

      assert settled.mode == :idle
      assert failed.mode == :idle
      assert abandoned.mode == :idle
    end

    test "stopping lives inside the running turn, so it cannot outlive one" do
      assert %State{mode: %Running{stopping: %State.Stopping{dropped: 0}}} = stopping()
    end
  end

  describe "queueing" do
    test "a message arriving while idle waits for nobody" do
      {state, effects} = State.queue(state(), Message.new("hello"))

      assert [{:emit, _source, %Event.MessageQueued{message: %Message{text: "hello"}}}] = effects
      assert View.status(state).pending == 1
    end

    test "a message sent again under the same id is taken once" do
      message = Message.new("hello", "m-1")
      {once, _effects} = State.queue(state(), message)

      assert {^once, []} = State.queue(once, message)
      assert {:run, _run, [^message], _state} = State.take(once)
    end

    test "a message arriving mid-turn asks that turn to wrap up" do
      {_state, effects} = State.queue(running(), Message.new("and another thing"))

      assert [{:emit, _source, %Event.MessageQueued{}}, {:ask_to_stop, pid}] = effects
      assert pid == self()
    end

    test "take/1 drains the queue only when there is nothing else happening" do
      {idle, _} = State.queue(state(), Message.new("hello"))
      {running, _} = State.queue(running(), Message.new("hello"))
      {waiting, _} = State.queue(waiting(), Message.new("hello"))

      assert {:run, _run, [%Message{text: "hello"}], drained} = State.take(idle)
      assert View.status(drained).pending == 0
      assert State.take(running) == :none
      assert State.take(waiting) == :none
    end

    test "nothing queued is nothing to run" do
      assert State.take(state()) == :none
    end
  end

  describe "one sender a turn" do
    defp maria, do: Wardrik.Principal.new(:channel, "slack/U1", name: "Maria")
    defp jon, do: Wardrik.Principal.new(:channel, "slack/U2", name: "jon")

    defp from(state, sender, text) do
      {state, _effects} = State.queue(state, Message.new(text, nil, sender: sender))
      state
    end

    defp asked_by(sender) do
      run =
        Run.root(Config.new(), Wardrik.AgentID.parse!("acme/@jon/assistant"), sender: sender)

      State.started(state(), task(), run, Conversation.new(), System.monotonic_time())
    end

    defp decider(principal, roles) do
      prefix = Wardrik.AgentID.Prefix.new!(org: "acme", user: "jon")
      %Wardrik.Token{principal: principal, scope: [Wardrik.Role.bind(roles, prefix)]}
    end

    test "a turn takes the oldest sender's messages, up to the next sender's" do
      state = state() |> from(maria(), "a") |> from(maria(), "b") |> from(jon(), "c")
      state = from(state, maria(), "d")

      assert {:run, run, [%Message{text: "a"}, %Message{text: "b"}], next} = State.take(state)
      assert Wardrik.Principal.same?(run.sender, maria())
      assert [%Message{text: "c"}, %Message{text: "d"}] = Enum.reverse(next.pending)

      assert {:run, run, [%Message{text: "c"}], _next} = State.take(next)
      assert Wardrik.Principal.same?(run.sender, jon())
    end

    test "messages nobody sent are answered together, as nobody's" do
      state = state() |> from(nil, "a") |> from(nil, "b")

      assert {:run, %Run{sender: nil}, [_a, _b], _next} = State.take(state)
    end

    test "a message mid-turn joins it only from the turn's sender" do
      {_state, own} = State.queue(asked_by(maria()), Message.new("more", nil, sender: maria()))
      {_state, other} = State.queue(asked_by(maria()), Message.new("me too", nil, sender: jon()))

      assert [{:emit, _source, %Event.MessageQueued{}}, {:ask_to_stop, _pid}] = own
      assert [{:emit, _source, %Event.MessageQueued{}}] = other
    end

    test "a parked turn waits as its sender's, and resumes as theirs" do
      {waiting, _effects} = State.parked(asked_by(maria()), parked_turn())

      assert %Waiting{sender: sender} = waiting.mode
      assert Wardrik.Principal.same?(sender, maria())
      assert {:resume, %Run{sender: ^sender}, _turn, _at} = State.resume(waiting)
    end

    test "the asker acting directly, or a token allowing it, decides the calls a turn waits on" do
      {waiting, _effects} = State.parked(asked_by(maria()), parked_turn())
      agent = Wardrik.Principal.new(:agent, "acme/@jon/assistant")
      asker = decider(maria(), [:reader])

      assert State.decides?(waiting, asker)
      assert State.decides?(waiting, decider(jon(), [:approver]))
      refute State.decides?(waiting, decider(jon(), [:reader, :messenger]))
      refute State.decides?(waiting, Wardrik.Token.assume(asker, agent, scope: asker.scope))
    end

    test "a turn nobody asked for is decided only by a token allowing it" do
      {waiting, _effects} = State.parked(running(), parked_turn())

      refute State.decides?(waiting, decider(jon(), [:reader]))
      assert State.decides?(waiting, Wardrik.Token.root(jon()))
    end
  end

  describe "interrupting" do
    test "a running turn is told to stop now and has a kill armed behind it" do
      {state, effects} = State.interrupt(running())

      assert [{:stop_now, _pid}, {:arm_kill, _task_ref, 2_000, 0}] = effects
      assert View.status(state).state == :running
    end

    test "what was queued is dropped and counted" do
      {queued, _} = State.queue(running(), Message.new("one"))
      {queued, _} = State.queue(queued, Message.new("two"))

      {state, effects} = State.interrupt(queued)

      assert {:arm_kill, _task_ref, _ms, 2} = List.last(effects)
      assert View.status(state).pending == 0
    end

    test "interrupting twice keeps the kill that is already armed" do
      armed = stopping()

      assert {^armed, []} = State.interrupt(armed)
    end

    test "a waiting turn is abandoned outright" do
      {state, effects} = State.interrupt(waiting())

      assert [{:emit, source, %Event.TurnInterrupted{stats: stats}}, {:close_turn, run}] =
               effects

      assert stats.resolution == :abandoned
      assert state.mode == :idle
      assert run.source == source
    end

    test "an idle agent says there was nothing to stop" do
      {_state, [{:emit, _source, %Event.TurnInterrupted{stats: stats}}]} =
        State.interrupt(state())

      assert stats.resolution == :idle
      assert stats.elapsed_ms == 0
    end
  end

  describe "the kill" do
    test "is armed for the running turn's task, and fires for it" do
      state = running()
      ref = state.mode.task.ref
      {state, [_stop, {:arm_kill, ^ref, _grace, 3}]} = State.interrupt(queued(state, 3))
      state = State.arm(state, make_ref(), 3)

      assert {:kill, idle, effects} = State.kill(state, ref)
      assert idle.mode == :idle

      assert [
               {:shutdown, _task},
               {:emit, _source, %Event.TurnInterrupted{stats: stats}},
               {:close_turn, _run}
             ] = effects

      assert stats.resolution == :killed
      assert stats.dropped == 3
    end

    test "a timer armed for another turn is refused" do
      assert State.kill(stopping(), make_ref()) == :stale
    end

    test "a timer that fired after the turn answered is refused" do
      stopping = stopping()
      {settled, _effects} = State.settled(stopping, [], [])

      assert State.kill(settled, stopping.mode.task.ref) == :stale
    end

    test "a turn that is not stopping is not killed" do
      running = running()
      assert State.kill(running, running.mode.task.ref) == :stale
    end

    test "an idle agent cannot be killed" do
      assert State.kill(state(), make_ref()) == :stale
    end
  end

  describe "clearing" do
    test "empties the history and its mark, and says how much it held" do
      {state, _effects} = State.settled(running(), [Assistant.new("read it")], ["outside"])

      assert {:ok, cleared, [{:emit, _source, %Event.ContextCleared{dropped: 1}}]} =
               State.clear(state)

      assert cleared.history.messages == []
      assert cleared.labels == []
    end

    test "is refused unless the agent is idle" do
      assert State.clear(running()) == {:error, :busy}
      assert State.clear(%{state() | mode: %Due{recovery: :owed}}) == {:error, :busy}
    end
  end

  describe "settling" do
    test "a turn that answered normally reports what it produced" do
      messages = [Assistant.new("done")]

      {state, [{:emit, source, event}, {:close_turn, run}]} =
        State.settled(running(), messages, [])

      assert event == %Event.TurnFinished{messages: messages}
      assert run.source == source
      assert Conversation.to_list(state.history) |> length() == 1
    end

    test "a turn that answered while stopping reports what the interrupt kept" do
      messages = [Assistant.new("partial")]
      {_state, effects} = State.settled(stopping(), messages, [])

      assert [
               {:emit, _source, %Event.TurnInterrupted{stats: stats}},
               {:close_turn, _run},
               {:cancel_kill, _timer}
             ] = effects

      assert stats.resolution == :stopped
      assert stats.kept == 1
    end

    test "answering before the kill was needed cancels it" do
      {_state, effects} = State.settled(stopping(), [], [])

      assert Enum.any?(effects, &match?({:cancel_kill, _timer}, &1))
    end

    test "a turn that never armed a kill has none to cancel" do
      {_state, effects} = State.settled(running(), [], [])

      refute Enum.any?(effects, &match?({:cancel_kill, _timer}, &1))
    end

    test "a turn leaves the labels of what it read on the history, and on every turn after" do
      {state, _effects} = State.settled(running(), [Assistant.new("read it")], ["outside"])
      assert state.labels == ["outside"]
      assert State.turn_run(state, nil).labels == ["outside"]

      {state, _effects} = State.settled(running(state), [Assistant.new("still")], ["books"])
      assert state.labels == ["books", "outside"]
      assert State.turn_run(state(), nil).labels == []
    end

    test "parking announces the calls a person has to answer" do
      {state, [{:emit, _source, %Event.TurnParked{calls: calls}} | _rest]} =
        State.parked(running(), parked_turn())

      assert [{%{id: "call_1"}, "Really?"}] = calls
      assert State.waiting_on(state) == calls
    end

    test "an agent that is not waiting is waiting on nothing" do
      assert State.waiting_on(state()) == []
      assert State.waiting_on(running()) == []
    end
  end

  describe "resuming" do
    test "a waiting agent hands back the turn it parked, under the source that parked" do
      %State{mode: %Waiting{source: source}} = state = waiting()

      assert {:resume, run, turn, started_at} = State.resume(state)
      assert run.source == source
      assert run.config == Config.new()
      assert %Turn{state: :waiting} = turn
      assert is_integer(started_at)
    end

    test "answering an agent that is not asking does nothing" do
      assert State.resume(state()) == :none
      assert State.resume(running()) == :none
    end
  end

  describe "whose result is whose" do
    test "only the turn in flight is recognised" do
      state = running()
      %Running{task: task} = state.mode

      assert State.running?(state, task.ref)
      refute State.running?(state, make_ref())
    end

    test "a result arriving after the agent settled belongs to nobody" do
      refute State.running?(state(), make_ref())
      refute State.running?(waiting(), make_ref())
    end
  end

  describe "answering another agent" do
    @asker Wardrik.AgentID.parse!("acme/front")

    defp asking(state \\ state(), id \\ "ask-1") do
      {state, _effects} = State.queue(state, Message.new("Which?", id, reply_to: [@asker]))
      {:run, _run, _messages, state} = State.take(state)
      running(state)
    end

    defp sent(effects), do: for({:send, to, message} <- effects, do: {to, message})

    test "a turn that finishes sends its answer, holding what it read, from the agent" do
      {state, effects} =
        State.settled(asking(), [Assistant.new("Two are open.")], ["outside"])

      assert [{@asker, %Message{} = answer}] = sent(effects)
      assert answer.id == "answer:ask-1"
      assert answer.text =~ "ask-1"
      assert answer.text =~ "Two are open."
      assert answer.labels == ["outside"]
      assert Wardrik.Principal.type(answer.sender) == :agent
      assert Wardrik.Principal.id(answer.sender) == "acme/@jon/assistant"
      assert answer.reply_to == []
      assert state.answering == []
    end

    test "a turn that ends in tool calls alone says it had no answer" do
      {_state, effects} = State.settled(asking(), [], [])
      assert [{@asker, %Message{text: text}}] = sent(effects)
      assert text =~ "without an answer"
    end

    test "each message a turn takes is answered, and one naming nobody is not" do
      {state, _effects} = State.queue(state(), Message.new("First?", "a", reply_to: [@asker]))
      {state, _effects} = State.queue(state, Message.new("Aside."))
      {state, _effects} = State.queue(state, Message.new("Second?", "b", reply_to: [@asker]))
      {:run, _run, _messages, state} = State.take(state)

      {_state, effects} = State.settled(running(state), [Assistant.new("Both.")], [])

      assert Enum.map(sent(effects), fn {_to, message} -> message.id end) == [
               "answer:a",
               "answer:b"
             ]
    end

    test "a turn that fails says so, holding nothing it read" do
      {_state, effects} = State.failed(asking(), :boom)
      assert [{@asker, %Message{labels: [], text: text}}] = sent(effects)
      assert text =~ "failed"
    end

    test "a turn that answers while stopping says it stopped, not what it kept" do
      {stopping, _effects} = State.interrupt(asking())
      stopping = State.arm(stopping, make_ref(), 0)

      {_state, effects} = State.settled(stopping, [Assistant.new("Half of it.")], ["outside"])
      assert [{@asker, %Message{labels: [], text: text}}] = sent(effects)
      assert text =~ "Stopped before answering"
    end

    test "a turn killed, or abandoned while waiting, says it stopped" do
      {stopping, _effects} = State.interrupt(asking())
      stopping = State.arm(stopping, make_ref(), 0)
      %State{mode: %Running{task: %Task{ref: ref}}} = stopping

      {:kill, _state, effects} = State.kill(stopping, ref)
      assert [{@asker, %Message{text: text}}] = sent(effects)
      assert text =~ "Stopped before answering"

      {waiting, _effects} = State.parked(asking(), parked_turn())
      {_state, effects} = State.interrupt(waiting)
      assert [{@asker, %Message{id: "answer:ask-1"}}] = sent(effects)
    end

    test "a message dropped from the queue says it stopped, and the turn still owes its own" do
      {state, _effects} =
        State.queue(asking(), Message.new("Later?", "ask-2", reply_to: [@asker]))

      {state, effects} = State.interrupt(state)

      assert [{@asker, %Message{id: "answer:ask-2"}}] = sent(effects)
      assert state.answering == [{@asker, "ask-1"}]

      {state, _effects} = State.queue(state(), Message.new("Idle?", "ask-3", reply_to: [@asker]))
      {_state, effects} = State.interrupt(state)
      assert [{@asker, %Message{id: "answer:ask-3"}}] = sent(effects)
    end

    test "what a turn owes is written down with it, and paid when it runs again" do
      state = asking() |> Stored.dump() |> Stored.load()
      assert state.answering == [{@asker, "ask-1"}]

      {:run, _run, [], state} = State.take(state)
      {_state, effects} = State.settled(running(state), [Assistant.new("Done.")], [])
      assert [{@asker, %Message{id: "answer:ask-1"}}] = sent(effects)
    end
  end

  describe "being written down" do
    defp reload(state), do: state |> Stored.dump() |> Stored.load()

    defp resumed do
      {:resume, run, turn, started_at} = State.resume(waiting())
      State.resumed(waiting(), task(), run, turn, %{"call_1" => {:deny, "No."}}, started_at)
    end

    # Pids, references, ports and functions, wherever they sit in a term.
    defp runtime_terms(term) when is_pid(term) or is_reference(term) or is_port(term),
      do: [term]

    defp runtime_terms(term) when is_function(term), do: [term]
    defp runtime_terms(%_{} = struct), do: struct |> Map.from_struct() |> runtime_terms()
    defp runtime_terms(map) when is_map(map), do: map |> Map.to_list() |> runtime_terms()
    defp runtime_terms(list) when is_list(list), do: Enum.flat_map(list, &runtime_terms/1)

    defp runtime_terms(tuple) when is_tuple(tuple),
      do: tuple |> Tuple.to_list() |> runtime_terms()

    defp runtime_terms(_other), do: []

    test "an idle agent comes back idle, with its queue" do
      {state, _effects} = State.queue(state(), Message.new("hello"))

      assert %State{mode: :idle, pending: [%Message{text: "hello"}]} = reload(state)
    end

    test "a turn in flight comes back owed, so take/1 runs it again" do
      state = reload(running())

      assert state.mode == %Due{recovery: :owed}
      assert %{state: :running} = View.status(state)
      assert {:run, _run, [], %State{mode: :idle}} = State.take(state)
    end

    test "an agent still owed a turn stays owed" do
      assert reload(reload(running())).mode == %Due{recovery: :owed}
    end

    test "interrupting a turn owed drops the queue, and nothing else" do
      {state, _effects} = State.queue(reload(running()), Message.new("hello"))

      assert {%State{mode: :idle, pending: []},
              [{:emit, _source, %Event.TurnInterrupted{stats: %{resolution: :idle, dropped: 1}}}]} =
               State.interrupt(state)
    end

    test "a parked turn comes back parked, with the call it stopped on" do
      state = reload(waiting())

      assert %State{mode: %Waiting{}} = state
      assert [{%{id: "call_1", name: "deploy"}, "Really?"}] = State.waiting_on(state)
    end

    test "a turn keeps who asked for it, in flight, owed or parked" do
      maria = Wardrik.Principal.new(:channel, "slack/U1", name: "Maria")

      run =
        Run.root(Config.new(), Wardrik.AgentID.parse!("acme/@jon/assistant"), sender: maria)

      running = State.started(state(), task(), run, Conversation.new(), System.monotonic_time())
      {waiting, _effects} = State.parked(running, parked_turn())

      assert %State{mode: %Due{recovery: :owed, sender: ^maria}} = owed = reload(running)
      assert {:run, %Run{sender: ^maria}, [], _state} = State.take(owed)
      assert %State{mode: %Waiting{sender: ^maria}} = reload(waiting)
    end

    test "a parked turn keeps the source that parked" do
      %State{mode: %Waiting{source: source}} = state = waiting()

      assert %State{mode: %Waiting{source: ^source}} = reload(state)
    end

    test "a turn resumed from a park comes back resuming, with the decisions it was given" do
      state = resumed()
      source = state.mode.run.source

      assert %State{
               mode: %Due{
                 recovery: {:resuming, _turn, %{"call_1" => {:deny, "No."}}},
                 source: ^source
               }
             } = reopened = reload(state)

      assert %{state: :running} = View.status(reopened)
      assert State.waiting_on(reopened) == []

      assert {:resume, run, %Turn{state: :waiting}, %{"call_1" => {:deny, "No."}}, _state} =
               State.take(reopened)

      assert run.source == source
      assert reload(reopened).mode == reopened.mode
    end

    test "interrupting a turn due to resume abandons it" do
      assert {%State{mode: :idle, outcome: :interrupted},
              [
                {:emit, _source, %Event.TurnInterrupted{stats: %{resolution: :abandoned}}},
                {:close_turn, _run}
              ]} =
               State.interrupt(reload(resumed()))
    end

    test "a turn that handed over a batch comes back replaying it, under its own trace" do
      state = running()
      source = state.mode.run.source
      {:ok, state} = State.checkpointed(state, self(), checkpoint())

      assert %State{
               mode: %Due{recovery: {:replaying, %Turn{remaining: 5}}, source: ^source}
             } = reopened = reload(state)

      assert %{state: :running} = View.status(reopened)
      assert {:replay, run, %Turn{}, _state} = State.take(reopened)
      assert run.source == source
      assert reload(reopened).mode == reopened.mode
    end

    test "a checkpoint is the furthest a turn got, past the park it resumed from" do
      {:ok, state} = State.checkpointed(resumed(), self(), checkpoint())
      assert %State{mode: %Due{recovery: {:replaying, _checkpoint}}} = reload(state)
    end

    test "only the running turn may hand over a batch" do
      assert :stale = State.checkpointed(running(), spawn(fn -> :ok end), checkpoint())
      assert :stale = State.checkpointed(state(), self(), checkpoint())
    end

    test "a replay started is running, with the checkpoint it began from" do
      state = State.replayed(state(), task(), run(), checkpoint(), System.monotonic_time())
      assert %State{mode: %Running{recovery: {:replaying, %Turn{}}}} = state
      assert %State{mode: %Due{recovery: {:replaying, %Turn{}}}} = reload(state)
    end

    # The history a turn began on, and the turn, having run a round of calls.
    defp asked,
      do:
        Conversation.new([
          User.new("Where is 1001?"),
          Assistant.new("Shipped."),
          User.new("1002?")
        ])

    defp went_on(%Turn{} = turn) do
      looked = Assistant.new("Looking.")
      found = %ToolResult{call_id: "call_0", name: "lookup", parts: [%Text{text: "Packed."}]}
      %{turn | context: Conversation.append(asked(), [looked, found]), messages: [looked, found]}
    end

    defp turn_of(%Waiting{turn: turn}), do: turn
    defp turn_of({:waiting, turn, _source, _sender}), do: turn
    defp turn_of(%Due{recovery: {:replaying, turn}}), do: turn
    defp turn_of(%Due{recovery: {:resuming, turn, _decisions}}), do: turn

    test "a turn is written as what it added, and read back on the history it began on" do
      running = State.started(state(), task(), run(), asked(), System.monotonic_time())
      parked = went_on(parked_turn())
      {:ok, checkpointed} = State.checkpointed(running, self(), went_on(checkpoint()))
      {waiting, _effects} = State.parked(running, parked)
      {:resume, run, turn, started_at} = State.resume(waiting)
      resumed = State.resumed(waiting, task(), run, turn, %{"call_1" => :approve}, started_at)

      for {state, turn} <- [
            {checkpointed, went_on(checkpoint())},
            {waiting, parked},
            {resumed, parked}
          ] do
        assert %Turn{context: nil, messages: [_looked, _found]} =
                 turn_of(Stored.dump(state).mode)

        assert turn_of(reload(state).mode) == turn
        assert turn_of(reload(reload(state)).mode) == turn
      end
    end

    test "interrupting a turn due to replay abandons it" do
      {:ok, state} = State.checkpointed(running(), self(), checkpoint())

      assert {%State{mode: :idle, outcome: :interrupted},
              [
                {:emit, _source, %Event.TurnInterrupted{stats: %{resolution: :abandoned}}},
                {:close_turn, _run}
              ]} =
               State.interrupt(reload(state))
    end

    test "who the work is for is the agent's ID, and no option" do
      id = Wardrik.AgentID.parse!("acme/@jon/x")
      state = State.new([], id)

      assert state.agent_id == id
      assert state.run_opts == []
    end

    test "the runner and resumer travel" do
      state =
        State.new(
          [config: Config.new(), runner: {SomeHost, :run, [:arg]}],
          Wardrik.AgentID.parse!("acme/@jon/assistant")
        )

      assert reload(state).runner == {SomeHost, :run, [:arg]}
    end

    test "a dump holds no processes, timers or callbacks" do
      {:ok, checkpointed} = State.checkpointed(running(), self(), checkpoint())

      for state <- [stopping(), waiting(), resumed(), checkpointed] do
        assert runtime_terms(Stored.dump(state)) == []
      end

      assert Stored.dump(stopping()).mode == %Due{recovery: :owed}
    end

    test "what it is doing is never written, and is read back from what it waits on" do
      refute Map.has_key?(Stored.dump(waiting()), :activity)

      assert %Activity{doing: %Event.TurnParked{calls: [{%{id: "call_1"}, "Really?"}]}} =
               reload(waiting()).activity

      assert %Activity{doing: :idle, pending: 2} = reload(queued(state(), 2)).activity
    end

    test "the host it runs on is never written, and every turn's run carries it" do
      host = Wardrik.Host.new(definitions: %Wardrik.Test.Definitions{})
      state = State.hosted(state(), host)

      refute Map.has_key?(Stored.dump(state), :host)
      assert reload(state).host == Wardrik.Host.new()
      assert State.turn_run(state, nil).host == host
    end

    test "a runner that is not an MFA is refused when the state is built" do
      assert_raise ArgumentError, ~r/must be \{module, function, args\}/, fn ->
        State.new(
          [runner: fn _run, _context -> :ok end],
          Wardrik.AgentID.parse!("acme/@jon/assistant")
        )
      end
    end
  end

  describe "what it is doing" do
    test "an event that changes it is announced on that event's span, and one that does not is not" do
      source = run().source
      asked = %Event.TurnStarted{messages: []}

      {state, effects} = State.heard(state(), Event.new(source, asked))

      assert [{:emit, ^source, %Event.ActivityChanged{activity: %Activity{doing: ^asked}}}] =
               effects

      assert {^state, []} = State.heard(state, Event.new(source, %Event.Result{text: "Hel"}))
      assert View.status(state).activity == state.activity
    end
  end

  describe "the view's meta/1" do
    test "reports what the fleet shows" do
      assert View.meta(state()) == %{
               status: :idle,
               pending: 0,
               waiting_on: [],
               outcome: nil
             }

      assert %{status: :running} = View.meta(running())
      assert %{status: :parked, waiting_on: ["deploy"]} = View.meta(waiting())
    end

    test "counts what is queued" do
      {state, _effects} = State.queue(state(), Message.new("hello"))

      assert %{pending: 1} = View.meta(state)
    end
  end
end
