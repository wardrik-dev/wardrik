defmodule Wardrik.AgentLedgerTest do
  use ExUnit.Case, async: false
  use Mimic

  alias Wardrik.Agent
  alias Wardrik.Event
  alias Wardrik.LLM.Config
  alias Wardrik.Test.LLMStub

  setup :set_mimic_global
  setup :verify_on_exit!

  # One tool that tells the test it has begun, then waits to be told to finish,
  # so a test can lose the agent part way through the call.
  defmodule Effect do
    @moduledoc false
    @behaviour Wardrik.Tool

    @impl true
    def tools({name, test_pid}) do
      [
        ReqLLM.Tool.new!(
          name: name,
          description: "Has an effect outside Wardrik.",
          parameter_schema: [],
          callback: fn _args ->
            send(test_pid, {:began, name, self()})

            receive do
              :finish -> {:ok, %{"done" => true}}
            end
          end
        )
      ]
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

  @careful [%Wardrik.Hook{name: "careful", module: Careful, value: nil}]

  @doc false
  def forward(_event, _measurements, metadata, test), do: send(test, {:forgotten, metadata})

  setup do
    key = Wardrik.Test.Fleet.id("ledger")
    :ok = Event.Bus.subscribe(key)
    %{key: key}
  end

  defp opts(extra) do
    [config: Config.new(tools: [{Effect, {"deploy", self()}}]), ledger: Wardrik.Ledger.Store] ++
      extra
  end

  # The node the agent ran on is gone: the agent, the turn and the tool it was
  # running all stop, with the call claimed and nothing settled.
  defp lose(key, tool) do
    {:dictionary, dictionary} = Process.info(tool, :dictionary)
    [caller | _callers] = Keyword.fetch!(dictionary, :"$callers")

    :ok = Wardrik.Fleet.stop(key)
    Enum.each([caller, tool], &Process.exit(&1, :kill))
  end

  test "a call lost part way through its batch does not run again unless a person says so", %{
    key: key
  } do
    LLMStub.stream([
      LLMStub.tool_call("call_1", "deploy", %{}),
      LLMStub.final_answer("It may have shipped.")
    ])

    {^key, agent} = Wardrik.Test.Fleet.start_agent(opts([]), key)
    Agent.ask(agent, "ship it")
    assert_receive {:began, "deploy", tool}, 5_000
    lose(key, tool)

    {:ok, agent} = Wardrik.Fleet.spawn(key, opts([]))

    assert_receive %Event{payload: {:turn_parked, [{%{id: "call_1"}, prompt}]}}, 5_000
    assert prompt =~ "may already have done what it does"
    refute_received {:began, "deploy", _tool}

    Agent.resume(agent, %{"call_1" => {:deny, "It shipped; leave it."}})

    assert_receive %Event{payload: {:turn_finished, _messages}}, 5_000
    refute_received {:began, "deploy", _tool}
  end

  test "a call lost after a person approved it asks again before it runs again", %{key: key} do
    LLMStub.stream([LLMStub.tool_call("call_1", "deploy", %{}), LLMStub.final_answer("Shipped.")])

    {^key, agent} = Wardrik.Test.Fleet.start_agent(opts(hooks: @careful), key)
    Agent.ask(agent, "ship it")
    assert_receive %Event{payload: {:turn_parked, [{%{id: "call_1"}, _prompt}]}}, 5_000

    Agent.resume(agent, %{"call_1" => :approve})
    assert_receive {:began, "deploy", tool}, 5_000
    lose(key, tool)

    # The approval stands; what is asked is whether the call may have run.
    {:ok, agent} = Wardrik.Fleet.spawn(key, opts(hooks: @careful))
    assert_receive %Event{payload: {:turn_parked, [{%{id: "call_1"}, prompt}]}}, 5_000
    assert prompt =~ "may already have done what it does"
    refute_received {:began, "deploy", _tool}

    Agent.resume(agent, %{"call_1" => :approve})

    assert_receive {:began, "deploy", tool}, 5_000
    send(tool, :finish)
    assert_receive %Event{payload: {:turn_finished, _messages}}, 5_000
  end

  test "an agent given hooks that allow the call it waits on carries on", %{key: key} do
    LLMStub.stream([LLMStub.tool_call("call_1", "deploy", %{}), LLMStub.final_answer("Shipped.")])

    {^key, agent} = Wardrik.Test.Fleet.start_agent(opts(hooks: @careful), key)
    Agent.ask(agent, "ship it")
    assert_receive %Event{payload: {:turn_parked, [{%{id: "call_1"}, _prompt}]}}, 5_000

    :ok = Agent.configure(agent, opts(hooks: @careful))
    assert [{%{id: "call_1"}, _prompt}] = Agent.parked(agent)
    refute_received {:began, "deploy", _tool}

    :ok = Agent.configure(agent, opts([]))

    assert_receive {:began, "deploy", tool}, 5_000
    send(tool, :finish)
    assert_receive %Event{payload: {:turn_finished, _messages}}, 5_000
  end

  test "a turn stopped with its agent stops, with the call it was making", %{key: key} do
    LLMStub.by_round([
      LLMStub.tool_call("call_1", "deploy", %{}),
      LLMStub.final_answer("It may have shipped.")
    ])

    {^key, agent} = Wardrik.Test.Fleet.start_agent(opts([]), key)
    Agent.ask(agent, "ship it")
    assert_receive %Event{payload: {:tool_started, call_id, "deploy", _, _}}, 5_000
    assert_receive {:began, "deploy", tool}, 5_000
    tool_ref = Process.monitor(tool)

    :ok = Wardrik.Fleet.stop(key)
    assert_receive {:DOWN, ^tool_ref, :process, ^tool, _reason}, 5_000

    # Replayed from its checkpoint, not asked again: the stub gives a model
    # asked again new call ids.
    {:ok, _agent} = Wardrik.Fleet.spawn(key, opts([]))
    assert_receive %Event{payload: {:turn_parked, [{%{id: ^call_id}, prompt}]}}, 5_000
    assert prompt =~ "may already have done what it does"
  end

  test "a call refused after it was lost part way tells the model it may have run", %{key: key} do
    LLMStub.stream([LLMStub.tool_call("call_1", "deploy", %{}), LLMStub.final_answer("Left it.")])

    {^key, agent} = Wardrik.Test.Fleet.start_agent(opts(hooks: @careful), key)
    Agent.ask(agent, "ship it")
    assert_receive %Event{payload: {:turn_parked, [{%{id: "call_1"}, _prompt}]}}, 5_000

    Agent.resume(agent, %{"call_1" => :approve})
    assert_receive {:began, "deploy", tool}, 5_000
    lose(key, tool)

    {:ok, agent} = Wardrik.Fleet.spawn(key, opts(hooks: @careful))
    assert_receive %Event{payload: {:turn_parked, [{%{id: "call_1"}, _prompt}]}}, 5_000

    Agent.resume(agent, %{"call_1" => {:deny, "Not today."}})

    assert_receive %Event{payload: {:tool_denied, "call_1", "deploy", reason}}, 5_000
    assert reason =~ "may already have done what it does"
    assert reason =~ "Not today."
    assert_receive %Event{payload: {:turn_finished, _messages}}, 5_000
  end

  test "a turn's claims are forgotten once it ends", %{key: key} do
    handler = "forgotten-#{key}"

    :ok =
      :telemetry.attach(handler, [:wardrik, :ledger, :forgotten], &__MODULE__.forward/4, self())

    on_exit(fn -> :telemetry.detach(handler) end)

    LLMStub.stream([LLMStub.tool_call("call_1", "deploy", %{}), LLMStub.final_answer("Shipped.")])

    {^key, agent} = Wardrik.Test.Fleet.start_agent(opts([]), key)
    Agent.ask(agent, "ship it")
    assert_receive {:began, "deploy", tool}, 5_000
    assert [_claim] = Wardrik.Store.keys(:claims, "#{key}//")
    send(tool, :finish)

    assert_receive %Event{payload: {:turn_finished, _}, source: %{trace: %{trace_id: trace_id}}},
                   5_000

    assert_receive {:forgotten, %{agent_id: ^key, trace_id: ^trace_id, answer: :ok}}, 5_000
    assert Wardrik.Store.keys(:claims, "#{key}//") == []
  end
end
