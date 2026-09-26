defmodule Tars.Agent.StateTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Context
  alias Tars.Agent.Message
  alias Tars.Agent.State
  alias Tars.Agent.State.Replaying
  alias Tars.Agent.State.Running
  alias Tars.Agent.State.Waiting
  alias Tars.LLM.Config
  alias Tars.LLM.Turn
  alias Tars.Scope

  defp state, do: State.new([config: Config.new()], "acme/jon/assistant")

  defp scope, do: Scope.root(Config.new(), "acme/jon/assistant", name: "turn")

  # A task nobody runs. The state never touches the process, only its ref.
  defp task, do: %Task{pid: self(), ref: make_ref(), owner: self(), mfa: {__MODULE__, :none, 0}}

  defp running(state \\ state()) do
    State.started(state, task(), scope(), Context.new(), System.monotonic_time())
  end

  defp parked_turn do
    call = %{id: "call_1", name: "deploy", arguments: %{}}

    %Turn{
      context: Context.new(),
      response: %ReqLLM.Response{
        id: "r",
        model: "m",
        context: Context.new(),
        finish_reason: :tool_calls
      },
      calls: [Tars.Test.AgentRunners.waiting(call, "Really?")],
      remaining: 5,
      revision: Tars.Hook.revision([]),
      state: :waiting
    }
  end

  defp checkpoint do
    %Turn{
      context: Context.new(),
      response: %ReqLLM.Response{
        id: "r",
        model: "m",
        context: Context.new(),
        finish_reason: :tool_calls
      },
      remaining: 5
    }
  end

  defp waiting do
    {state, _effects} = running() |> State.parked(parked_turn())
    state
  end

  defp stopping do
    {state, _effects} = State.interrupt(running())
    State.arm(state, make_ref(), make_ref(), 0)
  end

  describe "the mode" do
    test "a fresh agent is idle with nothing queued" do
      assert %{state: :idle, pending: 0} = State.status(state())
    end

    test "each mode reports itself" do
      assert State.status(running()).state == :running
      assert State.status(waiting()).state == :parked
    end

    test "starting a turn replaces idle rather than sitting beside it" do
      assert %State{mode: %Running{}} = running()
    end

    test "parking replaces the running turn, so neither outlives the other" do
      assert %State{mode: %Waiting{}} = waiting()
    end

    test "settling anything returns to idle" do
      {settled, _effects} = State.settled(running(), [])
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

      assert [{:emit, _source, {:message_queued, %Message{text: "hello"}}}] = effects
      assert State.status(state).pending == 1
    end

    test "a message sent again under the same id is taken once" do
      message = Message.new("hello", "m-1")
      {once, _effects} = State.queue(state(), message)

      assert {^once, []} = State.queue(once, message)
      assert {:run, [^message], _state} = State.take(once)
    end

    test "a message arriving mid-turn asks that turn to wrap up" do
      {_state, effects} = State.queue(running(), Message.new("and another thing"))

      assert [{:emit, _source, {:message_queued, _message}}, {:ask_to_stop, pid}] = effects
      assert pid == self()
    end

    test "take/1 drains the queue only when there is nothing else happening" do
      {idle, _} = State.queue(state(), Message.new("hello"))
      {running, _} = State.queue(running(), Message.new("hello"))
      {waiting, _} = State.queue(waiting(), Message.new("hello"))

      assert {:run, [%Message{text: "hello"}], drained} = State.take(idle)
      assert State.status(drained).pending == 0
      assert State.take(running) == :none
      assert State.take(waiting) == :none
    end

    test "nothing queued is nothing to run" do
      assert State.take(state()) == :none
    end
  end

  describe "interrupting" do
    test "a running turn is told to stop now and has a kill armed behind it" do
      {state, effects} = State.interrupt(running())

      assert [{:stop_now, _pid}, {:arm_kill, 2_000, 0}] = effects
      assert State.status(state).state == :running
    end

    test "what was queued is dropped and counted" do
      {queued, _} = State.queue(running(), Message.new("one"))
      {queued, _} = State.queue(queued, Message.new("two"))

      {state, effects} = State.interrupt(queued)

      assert {:arm_kill, _ms, 2} = List.last(effects)
      assert State.status(state).pending == 0
    end

    test "interrupting twice keeps the kill that is already armed" do
      armed = stopping()

      assert {^armed, []} = State.interrupt(armed)
    end

    test "a waiting turn is abandoned outright" do
      {state, effects} = State.interrupt(waiting())

      assert [{:emit, source, {:turn_interrupted, stats}}, {:close_turn, scope}] = effects
      assert stats.resolution == :abandoned
      assert state.mode == :idle
      assert scope.source == source
    end

    test "an idle agent says there was nothing to stop" do
      {_state, [{:emit, _source, {:turn_interrupted, stats}}]} = State.interrupt(state())

      assert stats.resolution == :idle
      assert stats.elapsed_ms == 0
    end
  end

  describe "the kill" do
    test "fires only for the tag that armed it" do
      tag = make_ref()
      {state, _} = State.interrupt(running())
      state = State.arm(state, tag, make_ref(), 3)

      assert {:kill, idle, effects} = State.kill(state, tag)
      assert idle.mode == :idle

      assert [
               {:shutdown, _task},
               {:emit, _source, {:turn_interrupted, stats}},
               {:close_turn, _scope}
             ] = effects

      assert stats.resolution == :killed
      assert stats.dropped == 3
    end

    test "a timer from an earlier interrupt is refused" do
      assert State.kill(stopping(), make_ref()) == :stale
    end

    test "a timer that fired after the turn answered is refused" do
      {settled, _effects} = State.settled(stopping(), [])

      assert State.kill(settled, make_ref()) == :stale
    end

    test "an idle agent cannot be killed" do
      assert State.kill(state(), make_ref()) == :stale
    end
  end

  describe "settling" do
    test "a turn that answered normally reports what it produced" do
      messages = [Context.assistant("done")]

      {state, [{:emit, source, event}, {:close_turn, scope}]} =
        State.settled(running(), messages)

      assert event == {:turn_finished, messages}
      assert scope.source == source
      assert Context.to_list(state.context) |> length() == 1
    end

    test "a turn that answered while stopping reports what the interrupt kept" do
      messages = [Context.assistant("partial")]
      {_state, effects} = State.settled(stopping(), messages)

      assert [
               {:emit, _source, {:turn_interrupted, stats}},
               {:close_turn, _scope},
               {:cancel_kill, _timer}
             ] = effects

      assert stats.resolution == :stopped
      assert stats.kept == 1
    end

    test "answering before the kill was needed cancels it" do
      {_state, effects} = State.settled(stopping(), [])

      assert Enum.any?(effects, &match?({:cancel_kill, _timer}, &1))
    end

    test "a turn that never armed a kill has none to cancel" do
      {_state, effects} = State.settled(running(), [])

      refute Enum.any?(effects, &match?({:cancel_kill, _timer}, &1))
    end

    test "parking announces the calls a person has to answer" do
      {state, [{:emit, _source, {:turn_parked, calls}} | _rest]} =
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

      assert {:resume, scope, turn, started_at} = State.resume(state)
      assert scope.source == source
      assert scope.config == Config.new()
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

  describe "being written down" do
    defp reload(state), do: state |> State.dump() |> State.load()

    defp resumed do
      {:resume, scope, turn, started_at} = State.resume(waiting())
      State.resumed(waiting(), task(), scope, turn, started_at)
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

    test "a queue written down before messages had ids comes back with ids" do
      dumped = %{State.dump(state()) | pending: ["hello"]}

      assert %State{pending: [%Message{id: id, text: "hello"}]} = State.load(dumped)
      assert is_binary(id)
    end

    test "a turn in flight comes back owed, so take/1 runs it again" do
      state = reload(running())

      assert state.mode == :owed
      assert {:run, [], _state} = State.take(state)
    end

    test "an agent still owed a turn stays owed" do
      assert reload(reload(running())).mode == :owed
    end

    test "a parked turn comes back parked, with the call it stopped on" do
      state = reload(waiting())

      assert %State{mode: %Waiting{}} = state
      assert [{%{id: "call_1", name: "deploy"}, "Really?"}] = State.waiting_on(state)
    end

    test "a parked turn keeps the source that parked" do
      %State{mode: %Waiting{source: source}} = state = waiting()

      assert %State{mode: %Waiting{source: ^source}} = reload(state)
    end

    test "a turn resumed from a park comes back parked on the same calls" do
      state = reload(resumed())

      assert %State{mode: %Waiting{}} = state
      assert [{%{id: "call_1"}, "Really?"}] = State.waiting_on(state)
    end

    test "a turn that handed over a batch comes back replaying it, under its own trace" do
      state = running()
      source = state.mode.scope.source
      {:ok, state} = State.checkpointed(state, self(), checkpoint())

      assert %State{mode: %Replaying{checkpoint: %Turn{remaining: 5}, source: ^source}} =
               reopened = reload(state)

      assert %{state: :running} = State.status(reopened)
      assert {:replay, scope, %Turn{}, _state} = State.take(reopened)
      assert scope.source == source
      assert reload(reopened).mode == reopened.mode
    end

    test "a checkpoint is the furthest a turn got, past the park it resumed from" do
      {:ok, state} = State.checkpointed(resumed(), self(), checkpoint())
      assert %State{mode: %Replaying{}} = reload(state)
    end

    test "only the running turn may hand over a batch" do
      assert :stale = State.checkpointed(running(), spawn(fn -> :ok end), checkpoint())
      assert :stale = State.checkpointed(state(), self(), checkpoint())
    end

    test "a replay started is running, with the checkpoint it began from" do
      state = State.replayed(state(), task(), scope(), checkpoint(), System.monotonic_time())
      assert %State{mode: %Running{checkpoint: %Turn{}}} = state
      assert %State{mode: %Replaying{}} = reload(state)
    end

    test "interrupting a turn due to replay abandons it" do
      {:ok, state} = State.checkpointed(running(), self(), checkpoint())

      assert {%State{mode: :idle, outcome: :interrupted},
              [
                {:emit, _source, {:turn_interrupted, %{resolution: :abandoned}}},
                {:close_turn, _scope}
              ]} =
               State.interrupt(reload(state))
    end

    test "who the work is for is read from the key" do
      assert State.new([], "acme/jon/x").scope_opts == [user: "jon", org: "acme"]
      assert State.new([], "_/_/x").scope_opts == [user: nil, org: nil]
    end

    test "the runner and resumer travel" do
      state =
        State.new([config: Config.new(), runner: {SomeHost, :run, [:arg]}], "acme/jon/assistant")

      assert reload(state).runner == {SomeHost, :run, [:arg]}
    end

    test "a dump holds no processes, timers or callbacks" do
      {:ok, checkpointed} = State.checkpointed(running(), self(), checkpoint())

      for state <- [stopping(), waiting(), resumed(), checkpointed] do
        assert runtime_terms(State.dump(state)) == []
      end

      assert State.dump(stopping()).mode == :owed
    end

    test "a runner that is not an MFA is refused when the state is built" do
      assert_raise ArgumentError, ~r/must be \{module, function, args\}/, fn ->
        State.new([runner: fn _scope, _context -> :ok end], "acme/jon/assistant")
      end
    end
  end

  describe "meta/1" do
    test "reports what the fleet shows" do
      assert State.meta(state()) == %{
               status: :idle,
               pending: 0,
               waiting_on: [],
               delegations: %{active: 0, total: 0},
               outcome: nil
             }

      assert %{status: :running} = State.meta(running())
      assert %{status: :parked, waiting_on: ["deploy"]} = State.meta(waiting())
    end

    test "counts what is queued" do
      {state, _effects} = State.queue(state(), Message.new("hello"))

      assert %{pending: 1} = State.meta(state)
    end
  end
end
