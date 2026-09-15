defmodule Tars.AgentTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias ReqLLM.Context
  alias Tars.Agent
  alias Tars.Event

  # Reports the context each turn was handed, then answers immediately.
  defp runner(test_pid, reply \\ "ok") do
    fn _scope, context ->
      send(test_pid, {:turn, snapshot(context)})
      {:ok, [Context.assistant(reply)]}
    end
  end

  # Same, but hands back its own pid and blocks until released, so a test can
  # hold a turn open for exactly as long as it needs without timing guesses.
  defp blocking_runner(test_pid, reply \\ "ok") do
    fn _scope, context ->
      send(test_pid, {:turn, snapshot(context), self()})
      receive do: (:release -> :ok)
      {:ok, [Context.assistant(reply)]}
    end
  end

  defp snapshot(context), do: Enum.map(context.messages, &{&1.role, text(&1)})

  defp text(message) do
    message.content
    |> Enum.filter(&(&1.type == :text))
    |> Enum.map_join(& &1.text)
  end

  defp start_agent(opts) do
    agent = start_supervised!({Agent, opts})
    # Unnamed agents use their own pid as the event id.
    :ok = Event.Bus.subscribe(agent)
    agent
  end

  defp roles(agent) do
    agent |> Agent.get_context() |> Context.to_list() |> Enum.map(& &1.role)
  end

  # A synchronous call is a barrier: when it returns, every cast this process
  # sent beforehand has already been handled.
  defp flush(agent), do: Agent.get_context(agent)

  test "ask/2 returns immediately and the turn runs asynchronously" do
    agent = start_agent(runner: runner(self()))

    assert :ok = Agent.ask(agent, "hello")

    assert_receive {:turn, [{:user, "hello"}]}
    assert_receive %Event{payload: {:turn_finished, [_assistant]}}
    assert roles(agent) == [:user, :assistant]
  end

  test "a second turn sees the first turn's result — turns never overlap" do
    agent = start_agent(runner: blocking_runner(self()))

    Agent.ask(agent, "first")
    assert_receive {:turn, [{:user, "first"}], first_turn}

    Agent.ask(agent, "second")
    flush(agent)
    send(first_turn, :release)

    assert_receive {:turn, [{:user, "first"}, {:assistant, "ok"}, {:user, "second"}], second_turn}
    send(second_turn, :release)
  end

  test "messages queued during a turn are batched into the next one, in order" do
    agent = start_agent(runner: blocking_runner(self()))

    Agent.ask(agent, "first")
    assert_receive {:turn, [{:user, "first"}], first_turn}

    Agent.ask(agent, "second")
    Agent.ask(agent, "third")
    flush(agent)
    send(first_turn, :release)

    assert_receive {:turn,
                    [
                      {:user, "first"},
                      {:assistant, "ok"},
                      {:user, "second"},
                      {:user, "third"}
                    ], second_turn}

    send(second_turn, :release)
  end

  test "context accumulates in order across turns" do
    agent = start_agent(runner: runner(self()))

    Agent.ask(agent, "one")
    assert_receive %Event{payload: {:turn_finished, _}}

    Agent.ask(agent, "two")
    assert_receive %Event{payload: {:turn_finished, _}}

    assert roles(agent) == [:user, :assistant, :user, :assistant]
  end

  test "a crashing turn does not take the agent down, and the queue drains" do
    test_pid = self()

    runner = fn _scope, context ->
      send(test_pid, {:turn, snapshot(context)})
      if text(List.last(context.messages)) == "boom", do: raise("kaboom")
      {:ok, [Context.assistant("ok")]}
    end

    capture_log(fn ->
      agent = start_agent(runner: runner)

      Agent.ask(agent, "boom")
      assert_receive {:turn, [{:user, "boom"}]}
      assert_receive %Event{payload: {:turn_failed, _reason}}

      # Still alive, still serving, and the failed turn left no result behind.
      Agent.ask(agent, "after")
      assert_receive {:turn, [{:user, "boom"}, {:user, "after"}]}
      assert Process.alive?(agent)
    end)
  end

  test "a turn that returns an error leaves context untouched" do
    runner = fn _scope, _context -> {:error, :rate_limited} end

    capture_log(fn ->
      agent = start_agent(runner: runner)

      Agent.ask(agent, "hello")

      assert_receive %Event{payload: {:turn_failed, :rate_limited}}
      assert roles(agent) == [:user]
    end)
  end

  test "stream events are published to subscribers, not routed through the agent" do
    runner = fn scope, _context ->
      Event.emit(scope.source, {:result, "streamed"})
      {:ok, [Context.assistant("ok")]}
    end

    agent = start_agent(runner: runner)

    Agent.ask(agent, "hello")

    assert_receive %Event{payload: {:result, "streamed"}}
  end

  describe "status/1" do
    test "reports idle with nothing pending" do
      agent = start_agent(runner: runner(self()))

      assert Agent.status(agent) == %{state: :idle, pending: 0}
    end

    test "reports running, and counts what is queued behind the turn" do
      agent = start_agent(runner: blocking_runner(self()))

      Agent.ask(agent, "first")
      assert_receive {:turn, [{:user, "first"}], first_turn}

      assert %{state: :running, pending: 0} = Agent.status(agent)

      Agent.ask(agent, "second")
      Agent.ask(agent, "third")

      assert %{state: :running, pending: 2} = Agent.status(agent)

      send(first_turn, :release)
      assert_receive {:turn, _snapshot, second_turn}
      send(second_turn, :release)
    end

    test "returns to idle once the turn ends" do
      agent = start_agent(runner: runner(self()))

      Agent.ask(agent, "hello")
      assert_receive %Event{payload: {:turn_finished, _}}

      assert %{state: :idle, pending: 0} = Agent.status(agent)
    end
  end

  test "a starting turn is announced before any output" do
    agent = start_agent(runner: runner(self()))

    Agent.ask(agent, "hello")

    assert_receive %Event{payload: {:turn_started, ["hello"]}}
    assert_receive %Event{payload: {:turn_finished, _}}
  end

  test "a turn's lifecycle events share one root span, and the next turn opens another" do
    agent = start_agent(runner: runner(self()))

    Agent.ask(agent, "one")
    assert_receive %Event{payload: {:turn_started, ["one"]}} = started
    assert_receive %Event{payload: {:turn_finished, _}} = finished

    Agent.ask(agent, "two")
    assert_receive %Event{payload: {:turn_started, ["two"]}} = next_turn

    assert Event.root?(started)
    assert started.source.trace.span_id == finished.source.trace.span_id
    assert next_turn.source.trace.trace_id != started.source.trace.trace_id
  end

  test "a failing turn closes on the span it opened" do
    runner = fn _scope, _context -> {:error, :rate_limited} end

    capture_log(fn ->
      agent = start_agent(runner: runner)

      Agent.ask(agent, "hello")

      assert_receive %Event{payload: {:turn_started, _}} = started
      assert_receive %Event{payload: {:turn_failed, :rate_limited}} = failed

      assert started.source.trace.span_id == failed.source.trace.span_id
    end)
  end

  test "the turn is handed a scope addressed to the agent" do
    test_pid = self()
    runner = fn scope, _context -> send(test_pid, {:scope, scope}) && {:ok, []} end

    agent = start_agent(runner: runner)
    Agent.ask(agent, "hello")

    assert_receive {:scope, scope}
    assert scope.source.agent_id == agent
    assert scope.config == Tars.LLM.Config.new()
    assert Tars.Trace.root?(scope.source.trace)
  end

  describe "messages from abandoned or unknown senders" do
    test "a stale task reply never touches context" do
      agent = start_agent(runner: runner(self()))

      Agent.ask(agent, "hello")
      assert_receive %Event{payload: {:turn_finished, _}}

      # Replies carrying a ref the agent is not waiting on.
      send(agent, {make_ref(), {:ok, [Context.assistant("injected")]}})
      send(agent, {make_ref(), {:error, :whatever}})

      assert roles(agent) == [:user, :assistant]
      assert Process.alive?(agent)
    end

    test "a stale DOWN does not clear the running turn" do
      agent = start_agent(runner: blocking_runner(self()))

      Agent.ask(agent, "first")
      assert_receive {:turn, [{:user, "first"}], first_turn}

      # Arrives while the real turn is still in flight.
      send(agent, {:DOWN, make_ref(), :process, self(), :normal})
      Agent.ask(agent, "second")
      flush(agent)
      send(first_turn, :release)

      assert_receive {:turn, [{:user, "first"}, {:assistant, "ok"}, {:user, "second"}],
                      second_turn}

      send(second_turn, :release)
    end

    test "an unrecognised message is ignored" do
      agent = start_agent(runner: runner(self()))

      capture_log(fn ->
        send(agent, :nonsense)
        assert roles(agent) == []
      end)

      assert Process.alive?(agent)
    end
  end

  describe "a message arriving mid-turn" do
    # Yields the moment it is asked to, so a test never guesses at timing.
    defp yielding_runner(test_pid) do
      fn _scope, _context ->
        send(test_pid, {:running, self()})

        receive do
          :yield -> send(test_pid, :yielded)
        after
          1_000 -> send(test_pid, :never_yielded)
        end

        {:ok, [Context.assistant("partial")]}
      end
    end

    test "asks the running turn to stop at its next boundary" do
      {:ok, agent} = Agent.start_link(runner: yielding_runner(self()))

      Agent.ask(agent, "one")
      assert_receive {:running, _pid}

      Agent.ask(agent, "two")

      assert_receive :yielded
    end

    test "starts the next turn against what the yielded one left behind" do
      test_pid = self()
      {:ok, agent} = Agent.start_link(runner: yielding_runner(test_pid))

      Agent.ask(agent, "one")
      assert_receive {:running, _pid}
      Agent.ask(agent, "two")
      assert_receive :yielded
      assert_receive {:running, _pid}

      # The second turn sees the first question, the partial answer it produced,
      # and the message that interrupted it — in that order.
      assert %{state: :running} = Agent.status(agent)

      context = Agent.get_context(agent)
      assert Enum.map(context.messages, & &1.role) == [:user, :assistant, :user]
    end

    test "nothing is nudged when nothing is running" do
      {:ok, agent} = Agent.start_link(runner: runner(self()))

      Agent.ask(agent, "one")

      assert_receive {:turn, _snapshot}
    end
  end

  describe "interrupt/1" do
    # Streams until interrupted, so a test never guesses at timing.
    defp streaming_runner(test_pid) do
      fn _scope, _context ->
        send(test_pid, {:running, self()})

        receive do
          :interrupt -> {:ok, [Context.assistant("half a th")]}
        after
          1_000 -> {:ok, [Context.assistant("never interrupted")]}
        end
      end
    end

    test "stops the running turn and keeps what it produced" do
      {:ok, agent} = Agent.start_link(runner: streaming_runner(self()))
      :ok = Event.Bus.subscribe(agent)

      Agent.ask(agent, "tell me a long story")
      assert_receive {:running, _pid}

      Agent.interrupt(agent)

      assert_receive %Event{payload: {:turn_interrupted, stats}}
      assert stats.resolution == :stopped
      assert stats.kept == 1

      context = Agent.get_context(agent)
      assert Enum.map(context.messages, & &1.role) == [:user, :assistant]
    end

    test "drops what was queued and says how much" do
      {:ok, agent} = Agent.start_link(runner: streaming_runner(self()))
      :ok = Event.Bus.subscribe(agent)

      Agent.ask(agent, "one")
      assert_receive {:running, _pid}
      Agent.ask(agent, "two")
      Agent.ask(agent, "three")

      Agent.interrupt(agent)

      assert_receive %Event{payload: {:turn_interrupted, %{dropped: 2}}}
      assert %{state: :idle, pending: 0} = Agent.status(agent)
    end

    test "reports an interrupt with nothing running rather than staying silent" do
      {:ok, agent} = Agent.start_link(runner: runner(self()))
      :ok = Event.Bus.subscribe(agent)

      Agent.interrupt(agent)

      assert_receive %Event{payload: {:turn_interrupted, %{resolution: :idle}}}
    end

    test "kills a turn that will not stop, and still settles idle" do
      test_pid = self()

      # Deaf on purpose: :interrupt lands in its mailbox and is never read,
      # which is what a turn stuck inside a tool call looks like.
      deaf = fn _scope, _context ->
        send(test_pid, {:running, self()})
        receive do: (:never -> :ok)
      end

      {:ok, agent} = Agent.start_link(runner: deaf)
      :ok = Event.Bus.subscribe(agent)

      Agent.ask(agent, "one")
      assert_receive {:running, _pid}

      Agent.interrupt(agent)

      assert_receive %Event{payload: {:turn_interrupted, stats}}, 5_000
      assert stats.resolution == :killed
      assert %{state: :idle} = Agent.status(agent)
    end

    test "leaves the agent able to take the next question" do
      {:ok, agent} = Agent.start_link(runner: streaming_runner(self()))
      :ok = Event.Bus.subscribe(agent)

      Agent.ask(agent, "one")
      assert_receive {:running, _pid}
      Agent.interrupt(agent)
      assert_receive %Event{payload: {:turn_interrupted, _stats}}

      Agent.ask(agent, "two")

      assert_receive {:running, _pid}
    end
  end
end
