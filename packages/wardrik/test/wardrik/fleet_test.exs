defmodule Wardrik.FleetTest do
  use ExUnit.Case, async: false

  alias ReqLLM.Context
  alias Wardrik.Agent
  alias Wardrik.Agent.Spec
  alias Wardrik.Delegation
  alias Wardrik.Event
  alias Wardrik.Fleet
  alias Wardrik.LLM.Config
  alias Wardrik.Test.AgentRunners

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
    test "puts a key without an org in the deployment's" do
      assert Fleet.key("researcher") == "default/researcher"
    end

    test "names the org, and the user marked with @" do
      assert Fleet.key("researcher", org: "acme") == "acme/researcher"
      assert Fleet.key("researcher", org: "acme", user: "jon") == "acme/@jon/researcher"
      assert Fleet.key("researcher", user: "jon") == "default/@jon/researcher"
    end

    test "writes host values down through Wardrik.Fleet.Segment" do
      assert Fleet.key("researcher", org: :acme, user: 7) == "acme/@7/researcher"
    end

    test "refuses a segment that is not one" do
      for opts <- [[org: "acme/eu"], [org: "_acme"], [org: "@acme"], [user: "jo n"], [user: ""]] do
        assert_raise ArgumentError, ~r/not a segment/, fn -> Fleet.key("researcher", opts) end
      end

      assert_raise ArgumentError, ~r/not a segment/, fn -> Fleet.key("acme/researcher") end
      assert_raise ArgumentError, ~r/not a segment/, fn -> Fleet.key("@researcher") end
    end

    test "refuses a key without an org where the deployment has none" do
      org = Application.get_env(:wardrik, Fleet)
      Application.delete_env(:wardrik, Fleet)
      on_exit(fn -> Application.put_env(:wardrik, Fleet, org) end)

      assert Fleet.org() == nil
      assert_raise ArgumentError, ~r/needs an org/, fn -> Fleet.key("researcher") end
      assert Fleet.key("researcher", org: "acme") == "acme/researcher"
      assert {:error, message} = Fleet.expand("researcher")
      assert message =~ "names no org"
    end

    test "a value with no Segment implementation says so" do
      assert_raise Protocol.UndefinedError, fn -> Fleet.key("researcher", user: %{id: 1}) end
    end
  end

  describe "parse/1" do
    test "splits a user's key and an org's" do
      assert Fleet.parse("acme/@jon/researcher") == {"acme", "jon", "researcher"}
      assert Fleet.parse("acme/researcher") == {"acme", nil, "researcher"}
    end

    test "refuses anything key/2 would not have built" do
      for key <- ["researcher", "a/b/c", "a/@b/c/d", "_/x", "a/@b", "@a/b", "a/_x", "a/ b"] do
        assert_raise ArgumentError, ~r|org/name or org/@user/name|, fn -> Fleet.parse(key) end
        assert Fleet.cast(key) == :error
      end
    end
  end

  describe "expand/1" do
    test "finds a name, or a user's name, in the deployment's org" do
      assert Fleet.expand("triage") == {:ok, "default/triage"}
      assert Fleet.expand("@jon/triage") == {:ok, "default/@jon/triage"}
    end

    test "takes a whole key as it is" do
      assert Fleet.expand("acme/triage") == {:ok, "acme/triage"}
      assert Fleet.expand("acme/@jon/triage") == {:ok, "acme/@jon/triage"}
    end

    test "refuses what names no agent" do
      for text <- ["", "@jon", "acme/@jon", "a/b/c", "_triage"] do
        assert {:error, message} = Fleet.expand(text)
        assert message =~ "not an agent key"
      end
    end
  end

  describe "expand_prefix/1" do
    test "reads an org, a user, or a user in the deployment's org" do
      assert Fleet.expand_prefix("") == {:ok, ""}
      assert Fleet.expand_prefix("acme/") == {:ok, "acme/"}
      assert Fleet.expand_prefix("acme/@jon/") == {:ok, "acme/@jon/"}
      assert Fleet.expand_prefix("@jon/") == {:ok, "default/@jon/"}
    end

    test "reads anything else as a key" do
      assert Fleet.expand_prefix("triage") == {:ok, "default/triage"}
      assert Fleet.expand_prefix("acme/@jon/triage") == {:ok, "acme/@jon/triage"}
      assert {:error, _message} = Fleet.expand_prefix("_x/")
    end
  end

  describe "scope/1" do
    test "reads an org, a user or a key, as the prefix it is" do
      assert Fleet.scope("") == {:ok, ""}
      assert Fleet.scope("acme") == {:ok, "acme/"}
      assert Fleet.scope("acme/@jon") == {:ok, "acme/@jon/"}
      assert Fleet.scope("acme/triage") == {:ok, "acme/triage"}
      assert Fleet.scope("acme/@jon/triage/") == {:ok, "acme/@jon/triage"}
    end

    test "refuses what is neither a prefix nor a key" do
      for text <- ["acme/jon/triage", "/acme", "acme/@/", "@jon/", "a/@b/c/d"] do
        assert {:error, message} = Fleet.scope(text)
        assert message =~ "not a scope"
      end
    end
  end

  describe "spawn/2" do
    test "starts an agent reachable by its key from anywhere" do
      key = Wardrik.Test.Fleet.key()
      pid = start(key, runner: runner(self()))

      assert Fleet.whereis(key) == pid
      assert :ok = Agent.ask(key, "hello")
      assert_receive {:turn, [{:user, "hello"}]}
    end

    test "returns the agent already holding the key rather than a second one" do
      key = Wardrik.Test.Fleet.key()
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
      key = Wardrik.Test.Fleet.key()
      pid = start(key, runner: runner(self()), node: node())

      assert node(pid) == node()
      assert Fleet.whereis(key) == pid
    end

    test "reports a node that cannot be reached" do
      assert {:error, {:erpc, :noconnection}} =
               Fleet.spawn(Wardrik.Test.Fleet.key(), node: :nowhere@nohost)
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
      key = Wardrik.Test.Fleet.key()
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
      assert [%{key: ^one}] = Fleet.list("#{org}/@jon/")
      assert Enum.all?(Fleet.list("#{org}/"), &(&1.status == :idle))
    end

    test "an agent reports that it is running, then parked" do
      key = Wardrik.Test.Fleet.key()
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

    test "a turn's delegations are followed from its lifecycle events, and the fleet how it ended" do
      key = Wardrik.Test.Fleet.key()
      pid = start(key, runner: {Wardrik.Test.AgentRunners, :delegating, [self(), "pricing"]})
      Event.Bus.subscribe(key, level: :lifecycle)

      assert %{outcome: nil} = Fleet.lookup(key)

      Agent.ask(pid, "go")
      assert_receive {:delegating, branch}
      assert_receive %Event{payload: {:delegation_started, "look into pricing"}} = started

      assert [%{name: "pricing", status: :running}] =
               Delegation.list(Delegation.fold(Delegation.new(), started))

      send(branch, :release)
      assert_receive %Event{payload: {:turn_finished, _messages}}

      assert Wardrik.Test.Fleet.await_update(fn -> match?(%{outcome: :ok}, Fleet.lookup(key)) end)
    end

    @tag capture_log: true
    test "a failed turn is reported as the last outcome" do
      key = Wardrik.Test.Fleet.key()
      pid = start(key, runner: {Wardrik.Test.AgentRunners, :failing, [:boom]})
      Event.Bus.subscribe(key, level: :lifecycle)

      Agent.ask(pid, "go")
      assert_receive %Event{payload: {:turn_failed, :boom}}

      assert Wardrik.Test.Fleet.await_update(fn -> Fleet.lookup(key).outcome == :failed end)
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
      key = Wardrik.Test.Fleet.key()
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
      key = Wardrik.Test.Fleet.key()
      pid = start(key, runner: runner(self()))
      Event.Bus.subscribe(key)

      Agent.ask(pid, "hello")
      assert_receive %Event{payload: {:turn_finished, _messages}}

      :ok = Fleet.stop(key)
      assert Fleet.whereis(key) == nil
      assert Fleet.stored?(key)
      {:ok, restarted} = Fleet.spawn(key, [])

      assert restarted != pid
      assert [:user, :assistant] = roles(restarted)

      :ok = Fleet.forget(key)
      refute Fleet.stored?(key)
    end

    test "a parked turn is still parked after a restart" do
      key = Wardrik.Test.Fleet.key()
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
      key = Wardrik.Test.Fleet.key()
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
      key = Wardrik.Test.Fleet.key()
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
      assert Agent.ask("no/such/agent", "hello") == {:error, :not_found}
      assert Agent.status("no/such/agent") == {:error, :not_found}
      assert Fleet.whereis("no/such/agent") == nil
      assert Fleet.lookup("no/such/agent") == nil
    end
  end

  defp roles(agent) do
    agent |> Agent.get_context() |> Context.to_list() |> Enum.map(& &1.role)
  end

  describe "put/1" do
    test "starts the agent a spec describes, then gives it what the spec says now" do
      spec =
        Spec.new(
          name: "put-#{System.unique_integer([:positive])}",
          org: "test",
          config: Config.new(model_spec: "anthropic:claude-sonnet-5")
        )

      key = Spec.key(spec)
      on_exit(fn -> Fleet.forget(key) end)

      assert {:ok, pid} = Fleet.put(spec)
      assert Agent.status(key).model == "anthropic:claude-sonnet-5"

      assert {:ok, ^pid} =
               Fleet.put(%{spec | config: Config.new(model_spec: "openai:gpt-5")})

      assert Agent.status(key).model == "openai:gpt-5"
    end
  end
end
