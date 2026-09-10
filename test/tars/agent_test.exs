defmodule Tars.AgentTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias ReqLLM.Context
  alias Tars.Agent
  alias Tars.Events

  # Reports the context each turn was handed, then answers immediately.
  defp runner(test_pid, reply \\ "ok") do
    fn _config, context ->
      send(test_pid, {:turn, snapshot(context)})
      {:ok, [Context.assistant(reply)]}
    end
  end

  # Same, but hands back its own pid and blocks until released, so a test can
  # hold a turn open for exactly as long as it needs without timing guesses.
  defp blocking_runner(test_pid, reply \\ "ok") do
    fn _config, context ->
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
    :ok = Events.subscribe(agent)
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
    assert_receive {:turn_finished, [_assistant]}
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
    assert_receive {:turn_finished, _}

    Agent.ask(agent, "two")
    assert_receive {:turn_finished, _}

    assert roles(agent) == [:user, :assistant, :user, :assistant]
  end

  test "a crashing turn does not take the agent down, and the queue drains" do
    test_pid = self()

    runner = fn _config, context ->
      send(test_pid, {:turn, snapshot(context)})
      if text(List.last(context.messages)) == "boom", do: raise("kaboom")
      {:ok, [Context.assistant("ok")]}
    end

    capture_log(fn ->
      agent = start_agent(runner: runner)

      Agent.ask(agent, "boom")
      assert_receive {:turn, [{:user, "boom"}]}
      assert_receive {:turn_failed, _reason}

      # Still alive, still serving, and the failed turn left no result behind.
      Agent.ask(agent, "after")
      assert_receive {:turn, [{:user, "boom"}, {:user, "after"}]}
      assert Process.alive?(agent)
    end)
  end

  test "a turn that returns an error leaves context untouched" do
    runner = fn _config, _context -> {:error, :rate_limited} end

    capture_log(fn ->
      agent = start_agent(runner: runner)

      Agent.ask(agent, "hello")

      assert_receive {:turn_failed, :rate_limited}
      assert roles(agent) == [:user]
    end)
  end

  test "stream events are published to subscribers, not routed through the agent" do
    runner = fn config, _context ->
      Events.emit(config.agent_id, {:result, "streamed"})
      {:ok, [Context.assistant("ok")]}
    end

    agent = start_agent(runner: runner)

    Agent.ask(agent, "hello")

    assert_receive {:result, "streamed"}
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
      assert_receive {:turn_finished, _}

      assert %{state: :idle, pending: 0} = Agent.status(agent)
    end
  end

  test "a starting turn is announced before any output" do
    agent = start_agent(runner: runner(self()))

    Agent.ask(agent, "hello")

    assert_receive {:turn_started, ["hello"]}
    assert_receive {:turn_finished, _}
  end

  describe "messages from abandoned or unknown senders" do
    test "a stale task reply never touches context" do
      agent = start_agent(runner: runner(self()))

      Agent.ask(agent, "hello")
      assert_receive {:turn_finished, _}

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
end
