defmodule Wardrik.FleetTest do
  use ExUnit.Case, async: false

  alias ReqLLM.Context
  alias Wardrik.Agent
  alias Wardrik.Agent.Spec
  alias Wardrik.AgentID
  alias Wardrik.AgentID.Prefix
  alias Wardrik.Delegation
  alias Wardrik.Event
  alias Wardrik.Fleet
  alias Wardrik.LLM.Config
  alias Wardrik.Run
  alias Wardrik.Test.AgentRunners

  import Wardrik.AgentID, only: [sigil_A: 2]

  defp runner(test_pid, reply \\ "ok"), do: {AgentRunners, :echo, [test_pid, reply]}
  defp parking_runner(test_pid), do: {AgentRunners, :parking, [test_pid, "call_1"]}
  defp blocking_runner(test_pid), do: {AgentRunners, :blocking, [test_pid, "ok"]}
  defp streaming_runner(test_pid), do: {AgentRunners, :streaming, [test_pid]}

  defp start(key, opts) do
    {:ok, pid} = Fleet.spawn(key, opts)
    on_exit(fn -> Fleet.forget(key) end)
    pid
  end

  describe "spawn/2" do
    test "starts an agent reachable by its ID from anywhere" do
      key = Wardrik.Test.Fleet.id()
      pid = start(key, runner: runner(self()))

      assert Fleet.whereis(key) == pid
      assert :ok = Agent.ask(key, "hello")
      assert_receive {:turn, [{:user, "hello"}]}
    end

    test "returns the agent already holding the ID rather than a second one" do
      key = Wardrik.Test.Fleet.id()
      pid = start(key, runner: runner(self()))

      assert {:ok, ^pid} = Fleet.spawn(key, runner: runner(self()))
    end

    test "the run names the agent it runs for" do
      key = AgentID.new!("planner", org: "acme", user: 42)
      pid = start(key, runner: {AgentRunners, :reporting, [self()]})

      Agent.ask(pid, "hi")

      assert_receive {:run, run}
      assert %AgentID{org: "acme", user: "42"} = Run.agent_id(run)
      assert %{id: %AgentID{org: "acme", user: "42", name: "planner"}} = Fleet.lookup(key)
    end

    test "places the agent on the node it is given" do
      key = Wardrik.Test.Fleet.id()
      pid = start(key, runner: runner(self()), node: node())

      assert node(pid) == node()
      assert Fleet.whereis(key) == pid
    end

    test "reports a node that cannot be reached" do
      assert {:error, {:erpc, :noconnection}} =
               Fleet.spawn(Wardrik.Test.Fleet.id(), node: :nowhere@nohost)
    end
  end

  describe "forget_under/1" do
    test "removes every running agent under a prefix and says how many" do
      org = "org#{System.unique_integer([:positive])}"
      keys = for name <- ["one", "two"], do: AgentID.new!(name, org: org)
      Enum.each(keys, &start(&1, runner: runner(self())))

      assert Fleet.forget_under(Prefix.new!(org: org)) == 2
      assert Fleet.list(Prefix.new!(org: org)) == []
      assert Fleet.forget_under(Prefix.new!(org: org)) == 0
    end
  end

  describe "move/2" do
    test "restarts an agent on the target node with the conversation it had" do
      key = Wardrik.Test.Fleet.id()
      pid = start(key, runner: runner(self()))
      Event.Bus.subscribe(key)
      Agent.ask(pid, "hello")
      assert_receive %Event{payload: %Event.TurnFinished{}}

      {:ok, moved} = Fleet.move(key, node())

      assert moved != pid
      assert node(moved) == node()
      assert Fleet.whereis(key) == moved
      assert [:user, :assistant] = roles(moved)
    end
  end

  describe "list/1" do
    test "reports every agent under a prefix, with what it is doing" do
      org = "org#{System.unique_integer([:positive])}"
      one = AgentID.new!("one", org: org)
      two = AgentID.new!("two", org: org)
      jons = AgentID.new!("one", org: org, user: "jon")
      start(one, runner: runner(self()))
      start(two, runner: runner(self()))
      start(jons, runner: runner(self()))

      assert [%{id: ^one}, %{id: ^two}] = Fleet.list(Prefix.new!(org: org))
      assert [%{id: ^jons}] = Fleet.list(Prefix.new!(org: org, user: "jon"))
      assert Enum.all?(Fleet.list(Prefix.new!(org: org)), &(&1.status == :idle))
    end

    test "an agent reports that it is running, then parked" do
      key = Wardrik.Test.Fleet.id()
      pid = start(key, runner: parking_runner(self()))
      Event.Bus.subscribe(key)

      Agent.ask(pid, "deploy")
      assert_receive %Event{payload: %Event.TurnParked{}}
      # A call is a barrier: the callback that parked has returned, so the
      # metadata it published is in the registry.
      assert [{_call, _prompt}] = Agent.parked(pid)

      assert %{status: :parked, waiting_on: ["deploy"]} = Fleet.lookup(key)
    end
  end

  describe "delegations" do
    setup do
      :ok = Fleet.watch()
      :ok
    end

    test "a turn's delegations are followed from its lifecycle events, and the fleet how it ended" do
      key = Wardrik.Test.Fleet.id()
      pid = start(key, runner: {Wardrik.Test.AgentRunners, :delegating, [self(), "pricing"]})
      Event.Bus.subscribe(key, level: :lifecycle)

      assert %{outcome: nil} = Fleet.lookup(key)

      Agent.ask(pid, "go")
      assert_receive {:delegating, branch}

      assert_receive %Event{payload: %Event.DelegationStarted{prompt: "look into pricing"}} =
                       started

      assert [%{name: "pricing", status: :running}] =
               Delegation.list(Delegation.fold(Delegation.new(), started))

      send(branch, :release)
      assert_receive %Event{payload: %Event.TurnFinished{}}

      assert Wardrik.Test.Fleet.await_update(fn -> match?(%{outcome: :ok}, Fleet.lookup(key)) end)
    end

    @tag capture_log: true
    test "a failed turn is reported as the last outcome" do
      key = Wardrik.Test.Fleet.id()
      pid = start(key, runner: {Wardrik.Test.AgentRunners, :failing, [:boom]})
      Event.Bus.subscribe(key, level: :lifecycle)

      Agent.ask(pid, "go")
      assert_receive %Event{payload: %Event.TurnFailed{reason: :boom}}

      assert Wardrik.Test.Fleet.await_update(fn -> Fleet.lookup(key).outcome == :failed end)
    end
  end

  describe "kill/1" do
    test "interrupts everything under a prefix and says how many" do
      org = "org#{System.unique_integer([:positive])}"
      one = AgentID.new!("one", org: org)
      two = AgentID.new!("two", org: org)
      start(one, runner: streaming_runner(self()))
      start(two, runner: streaming_runner(self()))
      Event.Bus.subscribe(one)
      Event.Bus.subscribe(two)

      Agent.ask(one, "go")
      Agent.ask(two, "go")
      assert_receive {:running, _pid_one}
      assert_receive {:running, _pid_two}

      assert Fleet.kill(Prefix.new!(org: org)) == 2

      assert_receive %Event{payload: %Event.TurnInterrupted{stats: %{resolution: :stopped}}},
                     1_000

      assert_receive %Event{payload: %Event.TurnInterrupted{stats: %{resolution: :stopped}}},
                     1_000
    end

    test "leaves agents outside the prefix alone" do
      key = Wardrik.Test.Fleet.id()
      pid = start(key, runner: runner(self()))

      assert Fleet.kill(Prefix.new!(org: "nothing-under-here")) == 0
      assert Process.alive?(pid)
    end
  end

  describe "watch/1" do
    test "reports an agent joining the fleet" do
      org = "org#{System.unique_integer([:positive])}"
      :ok = Fleet.watch(Prefix.new!(org: org))
      on_exit(fn -> Fleet.unwatch(Prefix.new!(org: org)) end)

      key = AgentID.new!("watched", org: org)
      start(key, runner: runner(self()))

      assert_receive {:group, events, _info}, 5_000
      assert Enum.any?(events, &(&1.type == :registered and &1.key == to_string(key)))
    end
  end

  describe "durability" do
    test "an agent comes back with the conversation it had" do
      key = Wardrik.Test.Fleet.id()
      pid = start(key, runner: runner(self()))
      Event.Bus.subscribe(key)

      Agent.ask(pid, "hello")
      assert_receive %Event{payload: %Event.TurnFinished{}}

      :ok = Fleet.stop(key)
      assert Fleet.whereis(key, wake: false) == nil
      assert Fleet.stored?(key)
      {:ok, restarted} = Fleet.spawn(key, [])

      assert restarted != pid
      assert [:user, :assistant] = roles(restarted)

      :ok = Fleet.forget(key)
      refute Fleet.stored?(key)
    end

    test "a parked turn is still parked after a restart" do
      key = Wardrik.Test.Fleet.id()
      pid = start(key, runner: parking_runner(self()))
      Event.Bus.subscribe(key)

      Agent.ask(pid, "deploy it")
      assert_receive %Event{payload: %Event.TurnParked{}}
      assert [{_call, _prompt}] = Agent.parked(pid)

      :ok = Fleet.stop(key)
      {:ok, restarted} = Fleet.spawn(key, [])

      assert [{%{id: "call_1", name: "deploy"}, "This ships to production."}] =
               Agent.parked(restarted)

      assert %{state: :parked} = Agent.status(restarted)
    end

    test "a turn that was running when the node went is run again" do
      key = Wardrik.Test.Fleet.id()
      test_pid = self()
      pid = start(key, runner: blocking_runner(test_pid))

      Agent.ask(pid, "slow one")
      assert_receive {:turn, [{:user, "slow one"}], _turn_pid}

      # Stopping syncs the state as it stands, which is mid-turn.
      # The runner comes back from the dump, so the turn runs the same way.
      :ok = Fleet.stop(key)
      {:ok, _restarted} = Fleet.spawn(key, [])

      assert_receive {:turn, [{:user, "slow one"}], _pid}, 5_000
    end

    test "a config's tools are rebuilt on the node that loads it" do
      key = Wardrik.Test.Fleet.id()
      config = Config.new(tools: [Wardrik.Test.EchoTool])
      pid = start(key, config: config, runner: runner(self()))

      :ok = Fleet.stop(key)
      {:ok, restarted} = Fleet.spawn(key, [])

      assert restarted != pid
      assert %{state: :idle} = Agent.status(restarted)
    end
  end

  describe "an agent that is not there" do
    test "answers rather than raising" do
      assert Agent.ask(~A"no/such-agent", "hello") == {:error, :not_found}
      assert Agent.status(~A"no/such-agent") == {:error, :not_found}
      assert Fleet.whereis(~A"no/such-agent") == nil
      assert Fleet.lookup(~A"no/such-agent") == nil
    end
  end

  defp roles(agent) do
    agent |> Agent.get_context() |> Context.to_list() |> Enum.map(& &1.role)
  end

  describe "put/1" do
    test "starts the agent a spec describes, then gives it what the spec says now" do
      spec =
        Spec.new(
          id: AgentID.new!("put-#{System.unique_integer([:positive])}", org: "test"),
          config: Config.new(model_spec: "anthropic:claude-sonnet-5")
        )

      key = spec.id
      on_exit(fn -> Fleet.forget(key) end)

      assert {:ok, pid} = Fleet.put(spec)
      assert Agent.status(key).model == "anthropic:claude-sonnet-5"

      assert {:ok, ^pid} =
               Fleet.put(%{spec | config: Config.new(model_spec: "openai:gpt-5")})

      assert Agent.status(key).model == "openai:gpt-5"
    end
  end
end
