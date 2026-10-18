defmodule Wardrik.LLM.ToolRunnerLedgerTest do
  use ExUnit.Case, async: true

  import Wardrik.Test, only: [host: 0]

  alias Wardrik.Call
  alias Wardrik.Event
  alias Wardrik.Ledger
  alias Wardrik.LLM.Config
  alias Wardrik.LLM.ToolRunner
  alias Wardrik.Run

  # A ledger that can be told to fail, for the one test that needs it.
  defmodule Unanswering do
    defstruct []
  end

  defimpl Wardrik.Ledger, for: Unanswering do
    def claim(_ledger, _key, _opts), do: {:error, :store_down}
    def settle(_ledger, _key, _opts), do: :ok
    def fetch(_ledger, _key, _opts), do: :error
    def release(_ledger, _key, _opts), do: :ok
    def forget(_ledger, _agent_id, _opts), do: :ok
  end

  # A tool that passes its call's idempotency key on, so it may run again.
  defmodule Rerunnable do
    @behaviour Wardrik.Tool

    @impl true
    def tool do
      Wardrik.Tool.new!(
        name: "refund",
        description: "Refunds an order, once per key.",
        schema: [],
        run: {__MODULE__, :run, []}
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
      schema: [],
      run: fn _input, _context ->
        send(test_pid, {:ran, name})
        answer
      end
    )
  end

  defp run(agent_id, tools, ledger \\ %Ledger.Store{}) do
    Config.new(tools: tools) |> Run.root(agent_id, name: "turn", ledger: ledger, host: host())
  end

  defp call(id, name), do: %{id: id, name: name, arguments: %{}}

  test "a call is claimed before it runs and settled with what it returned", %{agent_id: agent_id} do
    run = run(agent_id, [counted("refund")])
    call = call("call_1", "refund")

    assert %Call{id: "call_1", state: :done} = ToolRunner.execute(call, run)
    assert_received {:ran, "refund"}

    assert {:ok, %Ledger.Entry{result: {:ok, %{"done" => true}}}} =
             Ledger.fetch(%Ledger.Store{}, Ledger.Key.of(run, call), store: Wardrik.Test.store())
  end

  test "a call already settled is answered from the ledger without running", %{agent_id: agent_id} do
    run = run(agent_id, [counted("refund")])
    call = call("call_1", "refund")

    %Call{state: :done, result: first} = ToolRunner.execute(call, run)
    assert_received {:ran, "refund"}

    assert %Call{state: :done, result: ^first} = ToolRunner.execute(call, run)
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

    ToolRunner.execute(call, run(agent_id, tools))
    ToolRunner.execute(call, run(agent_id, tools))

    assert_received {:ran, "refund"}
    assert_received {:ran, "refund"}
  end

  test "a call claimed and never settled parks, and runs once a person approves running it again",
       %{agent_id: agent_id} do
    run = run(agent_id, [counted("refund")])
    call = call("call_1", "refund")

    :ok =
      Ledger.claim(
        %Ledger.Store{},
        Ledger.Key.of(run, call),
        call: call,
        store: Wardrik.Test.store()
      )

    assert %Call{state: :waiting, asks: [%Call.Ask{by: :doubt, prompt: prompt}]} =
             waiting = ToolRunner.execute(call, run)

    assert prompt =~ "may already have done what it does"
    refute_received {:ran, "refund"}

    assert %Call{state: :done} = waiting |> Call.approve() |> ToolRunner.execute(run)

    assert_received {:ran, "refund"}

    assert {:ok, %Ledger.Entry{result: {:ok, _}}} =
             Ledger.fetch(%Ledger.Store{}, Ledger.Key.of(run, call), store: Wardrik.Test.store())
  end

  test "a call claimed and never settled runs again under its key where its tool says it may",
       %{agent_id: agent_id} do
    run = run(agent_id, [Rerunnable])
    call = call("call_1", "refund")

    :ok =
      Ledger.claim(
        %Ledger.Store{},
        Ledger.Key.of(run, call),
        call: call,
        store: Wardrik.Test.store()
      )

    assert %Call{id: "call_1", state: :done} = ToolRunner.execute(call, run)

    key = Ledger.Key.idempotency(run, call)
    assert_received {:ran, "refund", ^key}

    assert {:ok, %Ledger.Entry{result: {:ok, %{"refunded" => true}}}} =
             Ledger.fetch(%Ledger.Store{}, Ledger.Key.of(run, call), store: Wardrik.Test.store())
  end

  test "approving what a hook asked runs nothing the ledger holds as begun", %{
    agent_id: agent_id
  } do
    run = run(agent_id, [counted("deploy")])
    call = call("call_1", "deploy")

    :ok =
      Ledger.claim(
        %Ledger.Store{},
        Ledger.Key.of(run, call),
        call: call,
        store: Wardrik.Test.store()
      )

    approved = %{
      Call.tool(call)
      | state: :approved,
        asks: [%Call.Ask{by: "careful", prompt: "Deploy?"}]
    }

    assert %Call{state: :waiting, asks: [%Call.Ask{by: :doubt, prompt: prompt}]} =
             ToolRunner.execute(approved, run)

    assert prompt =~ "may already have done what it does"
    refute_received {:ran, "deploy"}
  end

  test "the same call id in another batch of the turn is another call", %{agent_id: agent_id} do
    run = run(agent_id, [counted("refund")])
    call = call("call_0", "refund")

    ToolRunner.execute(call, Run.batch(run, 0))
    ToolRunner.execute(call, Run.batch(run, 1))

    assert_received {:ran, "refund"}
    assert_received {:ran, "refund"}

    refute Ledger.Key.of(Run.batch(run, 0), call) ==
             Ledger.Key.of(Run.batch(run, 1), call)
  end

  test "a tool that stops to ask releases its claim", %{agent_id: agent_id} do
    run = run(agent_id, [counted("connect", {:park, "Connect GitHub first."})])
    call = call("call_1", "connect")

    assert %Call{state: :waiting, asks: [%Call.Ask{by: :tool, prompt: "Connect GitHub first."}]} =
             ToolRunner.execute(call, run)

    assert :error =
             Ledger.fetch(%Ledger.Store{}, Ledger.Key.of(run, call), store: Wardrik.Test.store())
  end

  test "a call the ledger cannot answer for does not run", %{agent_id: agent_id} do
    run = run(agent_id, [counted("refund")], %Unanswering{})
    call = call("call_1", "refund")

    assert %Call{id: "call_1", state: :done} = ToolRunner.execute(call, run)
    refute_received {:ran, "refund"}

    assert_received %Event{
      payload: %Event.ToolDenied{call_id: "call_1", name: "refund", reason: reason}
    }

    assert reason =~ "could not record this call before running it"
  end

  describe "refusing a call" do
    test "that nothing began is a plain refusal", %{agent_id: agent_id} do
      run = run(agent_id, [counted("deploy")])

      assert %Call{state: :done} =
               ToolRunner.refuse(call("call_1", "deploy"), run, "Not today.")

      assert_received %Event{
        payload: %Event.ToolDenied{call_id: "call_1", name: "deploy", reason: "Not today."}
      }
    end

    test "that ran answers with what it returned", %{agent_id: agent_id} do
      run = run(agent_id, [counted("deploy")])
      call = call("call_1", "deploy")
      %Call{state: :done, result: ran} = ToolRunner.execute(call, run)

      assert %Call{state: :done, result: ^ran} = ToolRunner.refuse(call, run, "Not today.")

      assert_received %Event{
        payload: %Event.ToolReplayed{call_id: "call_1", name: "deploy", result: {:ok, _result}}
      }

      refute_received %Event{payload: %Event.ToolDenied{call_id: "call_1", name: "deploy"}}
    end

    test "that began and never finished tells the model it may have run", %{agent_id: agent_id} do
      run = run(agent_id, [counted("deploy")])
      call = call("call_1", "deploy")

      :ok =
        Ledger.claim(
          %Ledger.Store{},
          Ledger.Key.of(run, call),
          call: call,
          store: Wardrik.Test.store()
        )

      ToolRunner.refuse(call, run, "Not today.")

      assert_received %Event{
        payload: %Event.ToolDenied{call_id: "call_1", name: "deploy", reason: reason}
      }

      assert reason =~ "may already have done what it does"
      assert reason =~ "Not today."
      refute_received {:ran, "deploy"}
    end
  end

  test "forgetting a turn removes its calls and leaves other turns' alone", %{agent_id: agent_id} do
    turn = run(agent_id, [counted("refund")])
    other = run(agent_id, [counted("refund")])
    call = call("call_0", "refund")

    ToolRunner.execute(call, Run.batch(turn, 0))
    ToolRunner.execute(call, Run.batch(turn, 1))
    ToolRunner.execute(call, other)

    assert :ok =
             Ledger.forget(%Ledger.Store{}, agent_id,
               trace: turn.source.trace.trace_id,
               store: Wardrik.Test.store()
             )

    assert :error =
             Ledger.fetch(%Ledger.Store{}, Ledger.Key.of(Run.batch(turn, 0), call),
               store: Wardrik.Test.store()
             )

    assert :error =
             Ledger.fetch(%Ledger.Store{}, Ledger.Key.of(Run.batch(turn, 1), call),
               store: Wardrik.Test.store()
             )

    assert {:ok, _entry} =
             Ledger.fetch(%Ledger.Store{}, Ledger.Key.of(other, call),
               store: Wardrik.Test.store()
             )
  end

  test "idempotency_key/2 names one call in one turn", %{agent_id: agent_id} do
    run = run(agent_id, [])
    key = Ledger.Key.idempotency(run, call("call_1", "refund"))

    assert key == "#{agent_id}//#{run.source.trace.trace_id}/call_1"
    refute key == Ledger.Key.idempotency(run(agent_id, []), call("call_1", "refund"))
  end
end
