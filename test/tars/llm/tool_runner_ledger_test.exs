defmodule Tars.LLM.ToolRunnerLedgerTest do
  use ExUnit.Case, async: true

  alias Tars.Event
  alias Tars.Ledger
  alias Tars.LLM.Config
  alias Tars.LLM.ToolRunner
  alias Tars.Scope

  # A ledger that can be told to fail, for the one test that needs it.
  defmodule Unanswering do
    @behaviour Tars.Ledger
    @impl true
    def claim(_key, _call), do: {:error, :store_down}
    @impl true
    def settle(_key, _result), do: :ok
    @impl true
    def fetch(_key), do: :error
  end

  setup do
    agent_id = Tars.Test.Fleet.key()
    :ok = Event.Bus.subscribe(agent_id)
    {:ok, agent_id: agent_id}
  end

  # A tool that tells the test every time it runs.
  defp counted(name, answer \\ {:ok, %{"done" => true}}) do
    test_pid = self()

    ReqLLM.Tool.new!(
      name: name,
      description: "Does something with an effect.",
      parameter_schema: [],
      callback: fn _args ->
        send(test_pid, {:ran, name})
        answer
      end
    )
  end

  defp scope(agent_id, tools, ledger \\ Ledger.Store) do
    Config.new(tools: tools) |> Scope.root(agent_id, name: "turn", ledger: ledger)
  end

  defp call(id, name), do: %{id: id, name: name, arguments: %{}}

  test "a call is claimed before it runs and settled with what it returned", %{agent_id: agent_id} do
    scope = scope(agent_id, [counted("refund")])
    call = call("call_1", "refund")

    assert {:settled, ^call, _message} = ToolRunner.execute(call, scope)
    assert_received {:ran, "refund"}

    assert {:ok, %Ledger.Entry{result: {:ok, %{"done" => true}}}} =
             Ledger.fetch(Ledger.Store, Ledger.key(scope, call))
  end

  test "a call already settled is answered from the ledger without running", %{agent_id: agent_id} do
    scope = scope(agent_id, [counted("refund")])
    call = call("call_1", "refund")

    {:settled, ^call, first} = ToolRunner.execute(call, scope)
    assert_received {:ran, "refund"}

    assert {:settled, ^call, ^first} = ToolRunner.execute(call, scope)
    refute_received {:ran, "refund"}

    assert_received %Event{
      payload: {:tool_replayed, "call_1", "refund", {:ok, %{"done" => true}}}
    }
  end

  test "the same call id in another turn is another call", %{agent_id: agent_id} do
    tools = [counted("refund")]
    call = call("call_1", "refund")

    ToolRunner.execute(call, scope(agent_id, tools))
    ToolRunner.execute(call, scope(agent_id, tools))

    assert_received {:ran, "refund"}
    assert_received {:ran, "refund"}
  end

  test "a call claimed and never settled parks, and runs once a person approves", %{
    agent_id: agent_id
  } do
    scope = scope(agent_id, [counted("refund")])
    call = call("call_1", "refund")
    :ok = Ledger.claim(Ledger.Store, Ledger.key(scope, call), call)

    assert {:parked, ^call, prompt} = ToolRunner.execute(call, scope)
    assert prompt =~ "may already have done what it does"
    refute_received {:ran, "refund"}

    assert {:settled, ^call, _message} = ToolRunner.execute(call, scope, authorize: false)
    assert_received {:ran, "refund"}

    assert {:ok, %Ledger.Entry{result: {:ok, _}}} =
             Ledger.fetch(Ledger.Store, Ledger.key(scope, call))
  end

  test "a tool that stops to ask releases its claim", %{agent_id: agent_id} do
    scope = scope(agent_id, [counted("connect", {:park, "Connect GitHub first."})])
    call = call("call_1", "connect")

    assert {:parked, ^call, "Connect GitHub first."} = ToolRunner.execute(call, scope)
    assert :error = Ledger.fetch(Ledger.Store, Ledger.key(scope, call))
  end

  test "a call the ledger cannot answer for does not run", %{agent_id: agent_id} do
    scope = scope(agent_id, [counted("refund")], Unanswering)
    call = call("call_1", "refund")

    assert {:settled, ^call, _message} = ToolRunner.execute(call, scope)
    refute_received {:ran, "refund"}
    assert_received %Event{payload: {:tool_denied, "call_1", "refund", reason}}
    assert reason =~ "could not record this call before running it"
  end

  test "idempotency_key/2 names one call in one turn", %{agent_id: agent_id} do
    scope = scope(agent_id, [])
    key = Ledger.idempotency_key(scope, call("call_1", "refund"))

    assert key == "#{agent_id}/#{scope.source.trace.trace_id}/call_1"
    refute key == Ledger.idempotency_key(scope(agent_id, []), call("call_1", "refund"))
  end
end
