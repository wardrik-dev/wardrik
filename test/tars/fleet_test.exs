defmodule Tars.FleetTest do
  use ExUnit.Case, async: false

  alias ReqLLM.Context
  alias Tars.Agent
  alias Tars.Delegation
  alias Tars.Event
  alias Tars.Fleet
  alias Tars.Test.AgentRunners

  defp runner(test_pid, reply \\ "ok"), do: {AgentRunners, :echo, [test_pid, reply]}
  defp parking_runner(test_pid), do: {AgentRunners, :parking, [test_pid, "call_1"]}
  defp blocking_runner(test_pid), do: {AgentRunners, :blocking, [test_pid, "ok"]}
  defp streaming_runner(test_pid), do: {AgentRunners, :streaming, [test_pid]}

  defp start(key, opts) do
    {:ok, pid} = Fleet.spawn(key, opts)
    on_exit(fn -> Fleet.forget(key) end)
    pid
  end

  describe "key/2" do
    test "fills an absent org and user" do
      assert Fleet.key("researcher") == "_/_/researcher"
    end

    test "names the org and user a scope carries" do
      assert Fleet.key("researcher", org: "acme", user: "jon") == "acme/jon/researcher"
    end

    test "writes host values down through Tars.Fleet.Segment" do
      assert Fleet.key("researcher", org: :acme, user: 7) == "acme/7/researcher"
    end

    test "refuses a segment holding the separator" do
      assert_raise ArgumentError, ~r|may not contain|, fn ->
        Fleet.key("researcher", org: "acme/eu")
      end

      assert_raise ArgumentError, ~r|may not contain|, fn -> Fleet.key("acme/researcher") end
    end

    test "a value with no Segment implementation says so" do
      assert_raise Protocol.UndefinedError, fn -> Fleet.key("researcher", user: %{id: 1}) end
    end
  end

  describe "parse/1" do
    test "splits a full key" do
      assert Fleet.parse("acme/jon/researcher") == {"acme", "jon", "researcher"}
    end

    test "reports nil for an org or user the key does not carry" do
      assert Fleet.parse("_/_/researcher") == {nil, nil, "researcher"}
    end

    test "refuses anything key/2 would not have built" do
      assert_raise ArgumentError, ~r|org/user/name|, fn -> Fleet.parse("researcher") end
      assert_raise ArgumentError, ~r|org/user/name|, fn -> Fleet.parse("a/b/c/d") end
    end
  end

  describe "spawn/2" do
    test "starts an agent reachable by its key from anywhere" do
      key = Tars.Test.Fleet.key()
      pid = start(key, runner: runner(self()))

      assert Fleet.whereis(key) == pid
      assert :ok = Agent.ask(key, "hello")
      assert_receive {:turn, [{:user, "hello"}]}
    end

    test "returns the agent already holding the key rather than a second one" do
      key = Tars.Test.Fleet.key()
      pid = start(key, runner: runner(self()))

      assert {:ok, ^pid} = Fleet.spawn(key, runner: runner(self()))
    end

    test "the scope's identity is the key's" do
      key = Fleet.key("planner", org: "acme", user: 42)
      pid = start(key, runner: {AgentRunners, :reporting, [self()]})

      Agent.ask(pid, "hi")

      assert_receive {:scope, %{org: "acme", user: "42"}}
      assert %{org: "acme", user: "42", name: "planner"} = Fleet.lookup(key)
    end

    test "refuses a key that is not org/user/name" do
      assert_raise ArgumentError, fn -> Fleet.spawn("planner", []) end
    end

    test "places the agent on the node it is given" do
      key = Tars.Test.Fleet.key()
      pid = start(key, runner: runner(self()), node: node())

      assert node(pid) == node()
      assert Fleet.whereis(key) == pid
    end

    test "reports a node that cannot be reached" do
      assert {:error, {:erpc, :noconnection}} =
               Fleet.spawn(Tars.Test.Fleet.key(), node: :nowhere@nohost)
    end
  end

  describe "forget_under/1" do
    test "removes every running agent under a prefix and says how many" do
      org = "org#{System.unique_integer([:positive])}"
      keys = for name <- ["one", "two"], do: Fleet.key(name, org: org)
      Enum.each(keys, &start(&1, runner: runner(self())))

      assert Fleet.forget_under("#{org}/") == 2
      assert Fleet.list("#{org}/") == []
      assert Fleet.forget_under("#{org}/") == 0
    end
  end

  describe "move/2" do
    test "restarts an agent on the target node with the conversation it had" do
      key = Tars.Test.Fleet.key()
      pid = start(key, runner: runner(self()))
      Event.Bus.subscribe(key)
      Agent.ask(pid, "hello")
      assert_receive %Event{payload: {:turn_finished, _messages}}

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
      one = Fleet.key("one", org: org, user: "jon")
      two = Fleet.key("two", org: org, user: "sam")
      start(one, runner: runner(self()))
      start(two, runner: runner(self()))

      assert [%{key: ^one, name: "one", user: "jon"}, %{key: ^two}] = Fleet.list("#{org}/")
      assert [%{key: ^one}] = Fleet.list("#{org}/jon/")
      assert Enum.all?(Fleet.list("#{org}/"), &(&1.status == :idle))
    end

    test "an agent reports that it is running, then parked" do
      key = Tars.Test.Fleet.key()
      pid = start(key, runner: parking_runner(self()))
      Event.Bus.subscribe(key)

      Agent.ask(pid, "deploy")
      assert_receive %Event{payload: {:turn_parked, _calls}}
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

    test "an agent counts its turn's delegations, then how the turn ended" do
      key = Tars.Test.Fleet.key()
      pid = start(key, runner: {Tars.Test.AgentRunners, :delegating, [self(), "pricing"]})
      Event.Bus.subscribe(key, level: :lifecycle)

      assert %{delegations: %{active: 0, total: 0}, outcome: nil} = Fleet.lookup(key)

      Agent.ask(pid, "go")
      assert_receive {:delegating, branch}
      assert_receive %Event{payload: {:delegation_started, "look into pricing"}}

      assert Tars.Test.Fleet.await_update(fn ->
               Fleet.lookup(key).delegations == %{active: 1, total: 1}
             end)

      assert [%{name: "pricing", status: :running}] =
               Delegation.list(Agent.snapshot(pid).delegations)

      send(branch, :release)
      assert_receive %Event{payload: {:turn_finished, _messages}}

      assert Tars.Test.Fleet.await_update(fn ->
               match?(%{delegations: %{active: 0, total: 1}, outcome: :ok}, Fleet.lookup(key))
             end)

      assert [%{status: :ok, output: "found pricing"}] =
               Delegation.list(Agent.snapshot(pid).delegations)
    end

    @tag capture_log: true
    test "a failed turn is reported as the last outcome" do
      key = Tars.Test.Fleet.key()
      pid = start(key, runner: {Tars.Test.AgentRunners, :failing, [:boom]})
      Event.Bus.subscribe(key, level: :lifecycle)

      Agent.ask(pid, "go")
      assert_receive %Event{payload: {:turn_failed, :boom}}

      assert Tars.Test.Fleet.await_update(fn -> Fleet.lookup(key).outcome == :failed end)
    end
  end

  describe "kill/1" do
    test "interrupts everything under a prefix and says how many" do
      org = "org#{System.unique_integer([:positive])}"
      one = Fleet.key("one", org: org)
      two = Fleet.key("two", org: org)
      start(one, runner: streaming_runner(self()))
      start(two, runner: streaming_runner(self()))
      Event.Bus.subscribe(one)
      Event.Bus.subscribe(two)

      Agent.ask(one, "go")
      Agent.ask(two, "go")
      assert_receive {:running, _pid_one}
      assert_receive {:running, _pid_two}

      assert Fleet.kill("#{org}/") == 2

      assert_receive %Event{payload: {:turn_interrupted, %{resolution: :stopped}}}, 1_000
      assert_receive %Event{payload: {:turn_interrupted, %{resolution: :stopped}}}, 1_000
    end

    test "leaves agents outside the prefix alone" do
      key = Tars.Test.Fleet.key()
      pid = start(key, runner: runner(self()))

      assert Fleet.kill("nothing/under/here/") == 0
      assert Process.alive?(pid)
    end
  end

  describe "watch/1" do
    test "reports an agent joining the fleet" do
      org = "org#{System.unique_integer([:positive])}"
      :ok = Fleet.watch("#{org}/")
      on_exit(fn -> Fleet.unwatch("#{org}/") end)

      key = Fleet.key("watched", org: org)
      start(key, runner: runner(self()))

      assert_receive {:group, events, _info}, 5_000
      assert Enum.any?(events, &(&1.type == :registered and &1.key == key))
    end
  end

  describe "durability" do
    test "an agent comes back with the conversation it had" do
      key = Tars.Test.Fleet.key()
      pid = start(key, runner: runner(self()))
      Event.Bus.subscribe(key)

      Agent.ask(pid, "hello")
      assert_receive %Event{payload: {:turn_finished, _messages}}

      :ok = Fleet.stop(key)
      {:ok, restarted} = Fleet.spawn(key, [])

      assert restarted != pid
      assert [:user, :assistant] = roles(restarted)
    end

    test "a parked turn is still parked after a restart" do
      key = Tars.Test.Fleet.key()
      pid = start(key, runner: parking_runner(self()))
      Event.Bus.subscribe(key)

      Agent.ask(pid, "deploy it")
      assert_receive %Event{payload: {:turn_parked, _calls}}
      assert [{_call, _prompt}] = Agent.parked(pid)

      :ok = Fleet.stop(key)
      {:ok, restarted} = Fleet.spawn(key, [])

      assert [{%{id: "call_1", name: "deploy"}, "This ships to production."}] =
               Agent.parked(restarted)

      assert %{state: :parked} = Agent.status(restarted)
    end

    test "a turn that was running when the node went is run again" do
      key = Tars.Test.Fleet.key()
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
      key = Tars.Test.Fleet.key()
      config = Tars.LLM.Config.new(tools: [Tars.Test.EchoTool])
      pid = start(key, config: config, runner: runner(self()))

      :ok = Fleet.stop(key)
      {:ok, restarted} = Fleet.spawn(key, [])

      assert restarted != pid
      assert %{state: :idle} = Agent.status(restarted)
    end
  end

  describe "an agent that is not there" do
    test "answers rather than raising" do
      assert Agent.ask("no/such/agent", "hello") == {:error, :not_found}
      assert Agent.status("no/such/agent") == {:error, :not_found}
      assert Fleet.whereis("no/such/agent") == nil
      assert Fleet.lookup("no/such/agent") == nil
    end
  end

  defp roles(agent) do
    agent |> Agent.get_context() |> Context.to_list() |> Enum.map(& &1.role)
  end
end
