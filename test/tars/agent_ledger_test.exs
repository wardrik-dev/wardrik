defmodule Tars.AgentLedgerTest do
  use ExUnit.Case, async: false
  use Mimic

  alias Tars.Agent
  alias Tars.Event
  alias Tars.LLM.Config
  alias Tars.Test.LLMStub

  setup :set_mimic_global
  setup :verify_on_exit!

  # One tool that tells the test it has begun, then waits to be told to finish,
  # so a test can lose the agent part way through the call.
  defmodule Effect do
    @moduledoc false
    @behaviour Tars.Tool

    @impl true
    def tools({name, test_pid}) do
      [
        ReqLLM.Tool.new!(
          name: name,
          description: "Has an effect outside Tars.",
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
    @behaviour Tars.Policy

    @impl true
    def authorize(%{name: "deploy"}, _scope), do: {:ask, "This ships to production."}
    def authorize(_call, _scope), do: :allow
  end

  setup do
    key = Tars.Test.Fleet.key("ledger")
    :ok = Event.Bus.subscribe(key)
    %{key: key}
  end

  defp opts(extra) do
    [config: Config.new(tools: [{Effect, {"deploy", self()}}]), ledger: Tars.Ledger.Store] ++
      extra
  end

  # The node the agent ran on is gone: the agent, the turn and the tool it was
  # running all stop, with the call claimed and nothing settled.
  defp lose(key, tool) do
    {:dictionary, dictionary} = Process.info(tool, :dictionary)
    [caller | _callers] = Keyword.fetch!(dictionary, :"$callers")

    :ok = Tars.Fleet.stop(key)
    Enum.each([caller, tool], &Process.exit(&1, :kill))
  end

  test "a call lost part way through its batch does not run again unless a person says so", %{
    key: key
  } do
    LLMStub.stream([
      LLMStub.tool_call("call_1", "deploy", %{}),
      LLMStub.final_answer("It may have shipped.")
    ])

    {^key, agent} = Tars.Test.Fleet.start_agent(opts([]), key)
    Agent.ask(agent, "ship it")
    assert_receive {:began, "deploy", tool}, 5_000
    lose(key, tool)

    {:ok, agent} = Tars.Fleet.spawn(key, opts([]))

    assert_receive %Event{payload: {:turn_parked, [{%{id: "call_1"}, prompt}]}}, 5_000
    assert prompt =~ "may already have done what it does"
    refute_received {:began, "deploy", _tool}

    Agent.resume(agent, %{"call_1" => {:deny, "It shipped; leave it."}})

    assert_receive %Event{payload: {:turn_finished, _messages}}, 5_000
    refute_received {:began, "deploy", _tool}
  end

  test "a call lost after a person approved it asks again before it runs again", %{key: key} do
    LLMStub.stream([LLMStub.tool_call("call_1", "deploy", %{}), LLMStub.final_answer("Shipped.")])

    {^key, agent} = Tars.Test.Fleet.start_agent(opts(policy: Careful), key)
    Agent.ask(agent, "ship it")
    assert_receive %Event{payload: {:turn_parked, [{%{id: "call_1"}, _prompt}]}}, 5_000

    Agent.resume(agent, %{"call_1" => :approve})
    assert_receive {:began, "deploy", tool}, 5_000
    lose(key, tool)

    {:ok, agent} = Tars.Fleet.spawn(key, opts(policy: Careful))
    assert [{%{id: "call_1"}, "This ships to production."}] = Agent.parked(agent)

    Agent.resume(agent, %{"call_1" => :approve})

    assert_receive %Event{payload: {:turn_parked, [{%{id: "call_1"}, prompt}]}}, 5_000
    assert prompt =~ "may already have done what it does"
    refute_received {:began, "deploy", _tool}

    Agent.resume(agent, %{"call_1" => :approve})

    assert_receive {:began, "deploy", tool}, 5_000
    send(tool, :finish)
    assert_receive %Event{payload: {:turn_finished, _messages}}, 5_000
  end
end
