defmodule Wardrik.AgentSleepTest do
  use ExUnit.Case, async: false
  use Mimic

  alias Wardrik.Agent
  alias Wardrik.Agent.Spec
  alias Wardrik.Agent.State.Waiting
  alias Wardrik.Conversation.Assistant
  alias Wardrik.Conversation.ToolResult
  alias Wardrik.Conversation.User
  alias Wardrik.Event
  alias Wardrik.Fleet
  alias Wardrik.LLM.Config
  alias Wardrik.Test.AgentRunners
  alias Wardrik.Test.LLM

  @idle 50

  defp runner(test_pid), do: {AgentRunners, :echo, [test_pid, "ok"]}
  defp resumer(test_pid, result), do: {AgentRunners, :resuming, [test_pid, result]}

  defp start_agent(opts) do
    {key, _pid} = Wardrik.Test.Fleet.start_agent(Keyword.put_new(opts, :idle_timeout, @idle))
    :ok = Event.Bus.subscribe(key)
    key
  end

  defp asleep(key) do
    assert_receive %Event{payload: %Event.AgentStopped{reason: :idle}}, 2_000
    assert Wardrik.Test.Fleet.await_update(fn -> Fleet.held_pid(key, wake: false) == nil end)
  end

  test "an agent idle past its timeout stops, and its next message wakes it as it was" do
    key = start_agent(runner: runner(self()))

    :ok = Agent.ask(key, "hello", host: Wardrik.Test.host())
    assert_receive {:turn, [{:user, "hello"}]}
    asleep(key)

    assert %{asleep: true, status: :idle, pid: nil} = Fleet.lookup(key, host: Wardrik.Test.host())

    assert [%{id: ^key, asleep: true}] =
             Fleet.list(Wardrik.AgentID.resource(key), host: Wardrik.Test.host())

    :ok = Agent.ask(key, "again", host: Wardrik.Test.host())

    assert_receive {:turn, [{:user, "hello"}, {:assistant, "ok"}, {:user, "again"}]}
    assert %{asleep: false} = Fleet.lookup(key, host: Wardrik.Test.host())
  end

  test "an agent with something to do does not sleep" do
    key = start_agent(runner: {AgentRunners, :blocking, [self(), "ok"]})

    :ok = Agent.ask(key, "work", host: Wardrik.Test.host())
    assert_receive {:turn, _messages, turn}

    refute_receive %Event{payload: %Event.AgentStopped{reason: :idle}}, @idle * 4
    send(turn, :release)
    asleep(key)
  end

  test "an agent that never sleeps stays up" do
    key = start_agent(runner: runner(self()), idle_timeout: :infinity)

    :ok = Agent.ask(key, "hello", host: Wardrik.Test.host())
    assert_receive {:turn, _messages}

    refute_receive %Event{payload: %Event.AgentStopped{}}, @idle * 4
    assert is_pid(Fleet.held_pid(key, wake: false))
  end

  test "callers racing to wake a sleeping agent start one process between them" do
    key = start_agent(runner: runner(self()))
    asleep(key)

    pids =
      1..8
      |> Enum.map(fn _n ->
        Task.async(fn -> Fleet.whereis(key, host: Wardrik.Test.host()) end)
      end)
      |> Task.await_many()
      |> Enum.uniq()

    assert [pid] = pids
    assert is_pid(pid)
    assert Fleet.held_pid(key, wake: false) == pid
  end

  test "a sleeping agent asked what it waits on wakes and answers" do
    key = start_agent(runner: {AgentRunners, :parking, [self(), "call_1"]})

    :ok = Agent.ask(key, "ship it", host: Wardrik.Test.host())
    assert_receive %Event{payload: %Event.TurnParked{}}
    asleep(key)

    assert [{%{id: "call_1"}, _prompt}] = Agent.parked(key, host: Wardrik.Test.host())
  end

  test "a decision on a call parked before the agent slept carries the call on" do
    test_pid = self()
    answer = {:ok, [Assistant.new("shipped")]}

    key =
      start_agent(
        runner: {AgentRunners, :parking, [test_pid, "call_1"]},
        resumer: resumer(test_pid, answer)
      )

    :ok = Agent.ask(key, "ship it", host: Wardrik.Test.host())
    assert_receive %Event{payload: %Event.TurnParked{}}
    asleep(key)

    assert %{asleep: true, status: :parked, waiting_on: [_name]} =
             Fleet.lookup(key, host: Wardrik.Test.host())

    :ok =
      Agent.decide(
        key,
        %{"call_1" => :approve},
        token: Wardrik.Token.root(Wardrik.Principal.new(:shell, "root")),
        host: Wardrik.Host.new()
      )

    assert_receive {:resumed, %{"call_1" => :approve}}
    assert_receive %Event{payload: %Event.TurnFinished{}}
  end

  defmodule Tools do
    @moduledoc false
    @behaviour Wardrik.Tool

    @impl true
    def tools(_value) do
      for name <- ["lookup", "deploy"] do
        Wardrik.Tool.new!(
          name: name,
          description: "Does #{name}.",
          schema: [],
          run: fn _args, _context -> {:ok, %{"done" => name}} end
        )
      end
    end
  end

  defmodule Careful do
    @moduledoc false
    @behaviour Wardrik.Hook

    @impl true
    def init(_opts), do: nil

    @impl true
    def call(%Wardrik.Call{target: %Wardrik.Call.Tool{name: "deploy"}}, _value),
      do: {:ask, "This ships to production."}

    def call(_call, _value), do: :pass
  end

  defp waiting(key) do
    %{user_state: %{mode: %Waiting{turn: turn}}} =
      :sys.get_state(Fleet.held_pid(key, wake: false))

    turn
  end

  test "a turn parked a round in wakes as it was, and goes on with all it had said" do
    test_pid = self()

    LLM.answering(Wardrik.Test.llm(), fn %{messages: messages} ->
      send(test_pid, {:asked, messages})

      case Enum.count(messages, &match?(%Assistant{}, &1)) do
        0 -> LLM.tool_call("call_1", "lookup", %{})
        1 -> LLM.tool_call("call_2", "deploy", %{})
        _done -> LLM.final_answer("Shipped.")
      end
    end)

    key =
      start_agent(
        config: Config.new(tools: [{Tools, nil}]),
        hooks: [%Wardrik.Hook{name: "careful", module: Careful, value: nil}]
      )

    :ok = Agent.ask(key, "ship it", host: Wardrik.Test.host())
    assert_receive %Event{payload: %Event.TurnParked{}}, 5_000
    parked = waiting(key)
    asleep(key)

    assert [{%{id: "call_2"}, _prompt}] = Agent.parked(key, host: Wardrik.Test.host())
    assert waiting(key) == parked

    :ok =
      Agent.decide(key, %{"call_2" => :approve},
        token: Wardrik.Token.root(Wardrik.Principal.new(:shell, "root")),
        host: Wardrik.Test.host()
      )

    assert_receive {:asked, [%User{}, %Assistant{}, %ToolResult{}, %Assistant{}, %ToolResult{}]},
                   5_000

    assert_receive %Event{payload: %Event.TurnFinished{}}, 5_000
  end

  test "a sleeping agent parked on a credential wakes when it is connected" do
    test_pid = self()
    answer = {:ok, [Assistant.new("opened")]}
    link = %{url: "https://github.com/login/oauth", code: nil}
    credential = %{ref: "github", owner: {"acme", "jon"}}

    key =
      start_agent(
        runner: {AgentRunners, :connecting, [test_pid, "call_1", link, credential]},
        resumer: resumer(test_pid, answer)
      )

    :ok = Agent.ask(key, "open an issue", host: Wardrik.Test.host())
    assert_receive %Event{payload: %Event.TurnParked{}}
    asleep(key)

    :ok = Wardrik.Credential.available("github", {"acme", "someone-else"})
    assert Fleet.held_pid(key, wake: false) == nil

    :ok = Wardrik.Credential.available("github", {"acme", "jon"})

    assert_receive {:resumed, %{"call_1" => :approve}}, 2_000
  end

  test "moving a sleeping agent wakes it on the node it is moved to" do
    key = start_agent(runner: runner(self()))
    asleep(key)

    assert {:ok, pid} = Fleet.move(key, node())
    assert node(pid) == node()
    assert Fleet.held_pid(key, wake: false) == pid
  end

  test "a sleeping agent is forgotten with its prefix" do
    key = start_agent(runner: runner(self()))
    asleep(key)

    assert Fleet.forget_under(Wardrik.AgentID.resource(key)) == 1
    refute Fleet.stored?(key)
  end

  test "interrupting a sleeping agent wakes nothing" do
    key = start_agent(runner: runner(self()))
    asleep(key)

    assert {:error, :not_found} = Agent.interrupt(key)
    assert Fleet.held_pid(key, wake: false) == nil
  end

  test "an agent forgotten after it was found stored does not come back empty" do
    key = start_agent(runner: runner(self()))
    asleep(key)
    {:ok, info} = DurableServer.Supervisor.get_server_info(Wardrik.Fleet, to_string(key))
    :ok = Fleet.forget(key)

    # The store answers as it did before the agent was forgotten, once: the
    # check passes, and the start finds nothing.
    stub(DurableServer.Supervisor, :get_server_info, fn fleet, key ->
      call_original(DurableServer.Supervisor, :get_server_info, [fleet, key])
    end)

    expect(DurableServer.Supervisor, :get_server_info, fn _fleet, _key -> {:ok, info} end)

    assert Fleet.whereis(key, host: Wardrik.Test.host()) == nil
    assert Wardrik.Test.Fleet.await_update(fn -> Fleet.held_pid(key, wake: false) == nil end)
    refute Fleet.stored?(key)
  end

  test "an agent forgotten after its definition was found does not come back empty" do
    key = Wardrik.Test.Fleet.id()

    # The definition answers once, for the check, and is gone by the start.
    expect(WardrikStore, :get, fn _store, :test_definitions, _key -> Spec.new(id: key) end)

    assert Fleet.whereis(key, host: Wardrik.Test.host()) == nil
    assert Wardrik.Test.Fleet.await_update(fn -> Fleet.held_pid(key, wake: false) == nil end)
    refute Fleet.stored?(key)
  end

  test "an agent wakes with the definition the host answers for it now" do
    key = start_agent(runner: runner(self()), config: Config.new(model_spec: "test:before"))
    asleep(key)

    Wardrik.Test.Definitions.keep(
      key,
      Spec.new(id: key, config: Config.new(model_spec: "test:after"), idle_timeout: @idle)
    )

    assert %{model: "test:after"} = Agent.status(key, host: Wardrik.Test.host())
  end

  test "without a definition the host answers, an agent wakes as it slept" do
    key = start_agent(runner: runner(self()), config: Config.new(model_spec: "test:before"))
    asleep(key)

    assert %{model: "test:before"} = Agent.status(key, host: Wardrik.Test.host())
  end

  test "an agent starting takes the definition the host keeps of it" do
    key = Wardrik.Test.Fleet.id()

    Wardrik.Test.Definitions.keep(
      key,
      Spec.new(id: key, config: Config.new(model_spec: "test:kept"))
    )

    {^key, _pid} =
      Wardrik.Test.Fleet.start_agent([config: Config.new(model_spec: "test:given")], key)

    assert %{model: "test:kept"} = Agent.status(key, host: Wardrik.Test.host())
  end

  test "an ID nothing holds is not woken" do
    key = Wardrik.Test.Fleet.id()

    assert {:error, :not_found} = Agent.ask(key, "hello", host: Wardrik.Test.host())
    assert Fleet.whereis(key, host: Wardrik.Test.host()) == nil
    refute Fleet.stored?(key)
  end
end
