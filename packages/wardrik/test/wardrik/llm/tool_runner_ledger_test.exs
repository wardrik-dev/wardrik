defmodule Wardrik.LLM.ToolRunnerLedgerTest do
  use ExUnit.Case, async: true

  alias Wardrik.Call
  alias Wardrik.Event
  alias Wardrik.Ledger
  alias Wardrik.LLM.Config
  alias Wardrik.LLM.ToolRunner
  alias Wardrik.Scope

  # A ledger that can be told to fail, for the one test that needs it.
  defmodule Unanswering do
    @behaviour Wardrik.Ledger
    @impl true
    def claim(_key, _call), do: {:error, :store_down}
    @impl true
    def settle(_key, _result), do: :ok
    @impl true
    def fetch(_key), do: :error
  end

  # A tool that passes its call's idempotency key on, so it may run again.
  defmodule Rerunnable do
    @behaviour Wardrik.Tool

    @impl true
    def tool do
      Wardrik.Tool.new!(
        name: "refund",
        description: "Refunds an order, once per key.",
        parameter_schema: [],
        run: {__MODULE__, :run}
      )
    end

    @impl true
    def annotations("refund"), do: %{in_doubt: :rerun}

    def run(_input, %Wardrik.Tool.Context{idempotency_key: key}) do
      send(self(), {:ran, "refund", key})
      {:ok, %{"refunded" => true}}
    end
  end

  setup do
    agent_id = Wardrik.Test.Fleet.id()
    :ok = Event.Bus.subscribe(agent_id)
    {:ok, agent_id: agent_id}
  end

  # A tool that tells the test every time it runs.
  defp counted(name, answer \\ {:ok, %{"done" => true}}) do
    test_pid = self()

    Wardrik.Tool.new!(
      name: name,
      description: "Does something with an effect.",
      parameter_schema: [],
      run: fn _input, _context ->
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

    assert %Call{id: "call_1", state: :done} = ToolRunner.execute(call, scope)
    assert_received {:ran, "refund"}

    assert {:ok, %Ledger.Entry{result: {:ok, %{"done" => true}}}} =
             Ledger.fetch(Ledger.Store, Ledger.key(scope, call))
  end

  test "a call already settled is answered from the ledger without running", %{agent_id: agent_id} do
    scope = scope(agent_id, [counted("refund")])
    call = call("call_1", "refund")

    %Call{state: :done, result: first} = ToolRunner.execute(call, scope)
    assert_received {:ran, "refund"}

    assert %Call{state: :done, result: ^first} = ToolRunner.execute(call, scope)
    refute_received {:ran, "refund"}

    assert_received %Event{
      payload: %Event.ToolReplayed{
        call_id: "call_1",
        name: "refund",
        result: {:ok, %{"done" => true}}
      }
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

  test "a call claimed and never settled parks, and runs once a person approves running it again",
       %{agent_id: agent_id} do
    scope = scope(agent_id, [counted("refund")])
    call = call("call_1", "refund")
    :ok = Ledger.claim(Ledger.Store, Ledger.key(scope, call), call)

    assert %Call{state: :waiting, asks: [%Call.Ask{by: :doubt, prompt: prompt}]} =
             waiting = ToolRunner.execute(call, scope)

    assert prompt =~ "may already have done what it does"
    refute_received {:ran, "refund"}

    assert %Call{state: :done} = waiting |> Call.approve() |> ToolRunner.execute(scope)

    assert_received {:ran, "refund"}

    assert {:ok, %Ledger.Entry{result: {:ok, _}}} =
             Ledger.fetch(Ledger.Store, Ledger.key(scope, call))
  end

  test "a call claimed and never settled runs again under its key where its tool says it may",
       %{agent_id: agent_id} do
    scope = scope(agent_id, [Rerunnable])
    call = call("call_1", "refund")
    :ok = Ledger.claim(Ledger.Store, Ledger.key(scope, call), call)

    assert %Call{id: "call_1", state: :done} = ToolRunner.execute(call, scope)

    key = Ledger.idempotency_key(scope, call)
    assert_received {:ran, "refund", ^key}

    assert {:ok, %Ledger.Entry{result: {:ok, %{"refunded" => true}}}} =
             Ledger.fetch(Ledger.Store, Ledger.key(scope, call))
  end

  test "approving what a hook asked runs nothing the ledger holds as begun", %{
    agent_id: agent_id
  } do
    scope = scope(agent_id, [counted("deploy")])
    call = call("call_1", "deploy")
    :ok = Ledger.claim(Ledger.Store, Ledger.key(scope, call), call)

    approved = %{
      Call.tool(call)
      | state: :approved,
        asks: [%Call.Ask{by: "careful", prompt: "Deploy?"}]
    }

    assert %Call{state: :waiting, asks: [%Call.Ask{by: :doubt, prompt: prompt}]} =
             ToolRunner.execute(approved, scope)

    assert prompt =~ "may already have done what it does"
    refute_received {:ran, "deploy"}
  end

  test "the same call id in another batch of the turn is another call", %{agent_id: agent_id} do
    scope = scope(agent_id, [counted("refund")])
    call = call("call_0", "refund")

    ToolRunner.execute(call, Scope.batch(scope, 0))
    ToolRunner.execute(call, Scope.batch(scope, 1))

    assert_received {:ran, "refund"}
    assert_received {:ran, "refund"}
    refute Ledger.key(Scope.batch(scope, 0), call) == Ledger.key(Scope.batch(scope, 1), call)
  end

  test "a tool that stops to ask releases its claim", %{agent_id: agent_id} do
    scope = scope(agent_id, [counted("connect", {:park, "Connect GitHub first."})])
    call = call("call_1", "connect")

    assert %Call{state: :waiting, asks: [%Call.Ask{by: :tool, prompt: "Connect GitHub first."}]} =
             ToolRunner.execute(call, scope)

    assert :error = Ledger.fetch(Ledger.Store, Ledger.key(scope, call))
  end

  test "a call the ledger cannot answer for does not run", %{agent_id: agent_id} do
    scope = scope(agent_id, [counted("refund")], Unanswering)
    call = call("call_1", "refund")

    assert %Call{id: "call_1", state: :done} = ToolRunner.execute(call, scope)
    refute_received {:ran, "refund"}

    assert_received %Event{
      payload: %Event.ToolDenied{call_id: "call_1", name: "refund", reason: reason}
    }

    assert reason =~ "could not record this call before running it"
  end

  describe "refusing a call" do
    test "that nothing began is a plain refusal", %{agent_id: agent_id} do
      scope = scope(agent_id, [counted("deploy")])

      assert %Call{state: :done} =
               ToolRunner.refuse(call("call_1", "deploy"), scope, "Not today.")

      assert_received %Event{
        payload: %Event.ToolDenied{call_id: "call_1", name: "deploy", reason: "Not today."}
      }
    end

    test "that ran answers with what it returned", %{agent_id: agent_id} do
      scope = scope(agent_id, [counted("deploy")])
      call = call("call_1", "deploy")
      %Call{state: :done, result: ran} = ToolRunner.execute(call, scope)

      assert %Call{state: :done, result: ^ran} = ToolRunner.refuse(call, scope, "Not today.")

      assert_received %Event{
        payload: %Event.ToolReplayed{call_id: "call_1", name: "deploy", result: {:ok, _result}}
      }

      refute_received %Event{payload: %Event.ToolDenied{call_id: "call_1", name: "deploy"}}
    end

    test "that began and never finished tells the model it may have run", %{agent_id: agent_id} do
      scope = scope(agent_id, [counted("deploy")])
      call = call("call_1", "deploy")
      :ok = Ledger.claim(Ledger.Store, Ledger.key(scope, call), call)

      ToolRunner.refuse(call, scope, "Not today.")

      assert_received %Event{
        payload: %Event.ToolDenied{call_id: "call_1", name: "deploy", reason: reason}
      }

      assert reason =~ "may already have done what it does"
      assert reason =~ "Not today."
      refute_received {:ran, "deploy"}
    end
  end

  test "forgetting a turn removes its calls and leaves other turns' alone", %{agent_id: agent_id} do
    turn = scope(agent_id, [counted("refund")])
    other = scope(agent_id, [counted("refund")])
    call = call("call_0", "refund")

    ToolRunner.execute(call, Scope.batch(turn, 0))
    ToolRunner.execute(call, Scope.batch(turn, 1))
    ToolRunner.execute(call, other)

    assert :ok = Ledger.Store.forget(agent_id, turn.source.trace.trace_id)

    assert :error = Ledger.fetch(Ledger.Store, Ledger.key(Scope.batch(turn, 0), call))
    assert :error = Ledger.fetch(Ledger.Store, Ledger.key(Scope.batch(turn, 1), call))
    assert {:ok, _entry} = Ledger.fetch(Ledger.Store, Ledger.key(other, call))
  end

  test "idempotency_key/2 names one call in one turn", %{agent_id: agent_id} do
    scope = scope(agent_id, [])
    key = Ledger.idempotency_key(scope, call("call_1", "refund"))

    assert key == "#{agent_id}//#{scope.source.trace.trace_id}/call_1"
    refute key == Ledger.idempotency_key(scope(agent_id, []), call("call_1", "refund"))
  end
end
