defmodule Wardrik.LLM.ToolRunnerLedgerTest do
  use ExUnit.Case, async: true

  import Wardrik.Test, only: [host: 0, host: 1, store: 0]

  alias Wardrik.Bus
  alias Wardrik.Call
  alias Wardrik.Ledger
  alias Wardrik.LLM.Config
  alias Wardrik.LLM.ToolRunner
  alias Wardrik.Run

  # A store that refuses every write, for the one test that needs it.
  defmodule Unwritable do
    defstruct []
  end

  defimpl WardrikStore.Adapter, for: Unwritable do
    def child_spec(_store), do: %{id: Unwritable, start: {Function, :identity, [:ignore]}}
    def check(_store), do: {:error, "down"}
    def quorum(_store, _size), do: 1
    def durable_backend(_store), do: raise("down")
    def put(_store, _ns, _key, _value, _opts), do: {:error, :store_down}
    def get(_store, _ns, _key, _opts), do: nil
    def lookup(_store, _ns, _key), do: nil
    def delete(_store, _ns, _key, _opts), do: {:error, :store_down}
    def keys(_store, _ns, _prefix), do: []
  end

  # A store that takes claims and raises on the write that settles one, as a
  # connection dropped after a tool ran does.
  defmodule Unsettling do
    defstruct [:store]
  end

  defimpl WardrikStore.Adapter, for: Unsettling do
    def child_spec(%{store: store}), do: WardrikStore.child_spec(store)
    def check(%{store: store}), do: WardrikStore.Adapter.check(store)
    def quorum(_store, _size), do: 1
    def durable_backend(%{store: store}), do: WardrikStore.durable_backend(store)

    def put(_unsettling, _ns, _key, _value, if_vsn: vsn) when vsn != nil,
      do: raise("connection closed")

    def put(%{store: store}, ns, key, value, opts),
      do: WardrikStore.put(store, ns, key, value, opts)

    def get(%{store: store}, ns, key, opts), do: WardrikStore.get(store, ns, key, opts)
    def lookup(%{store: store}, ns, key), do: WardrikStore.lookup(store, ns, key)
    def delete(%{store: store}, ns, key, opts), do: WardrikStore.delete(store, ns, key, opts)
    def keys(%{store: store}, ns, prefix), do: WardrikStore.keys(store, ns, prefix)
  end

  # A tool that passes its call's idempotency key on, so it may run again.
  defmodule Rerunnable do
    use Wardrik.Tool

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
    :ok = Bus.subscribe(agent_id)
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

  defp run(agent_id, tools, host \\ host()) do
    Config.new(tools: tools) |> Run.root(agent_id, name: "turn", host: host)
  end

  defp call(id, name), do: %{id: id, name: name, arguments: %{}}

  test "a call is claimed before it runs and settled with what it returned", %{agent_id: agent_id} do
    run = run(agent_id, [counted("refund")])
    call = call("call_1", "refund")

    assert %Call{id: "call_1", state: :done} = ToolRunner.execute(call, run)
    assert_received {:ran, "refund"}

    assert {:ok, %Ledger.Entry{result: {:ok, %{"done" => true}}}} =
             Ledger.fetch(store(), Ledger.Key.of(run, call))
  end

  test "a call already settled is answered from the ledger without running", %{agent_id: agent_id} do
    run = run(agent_id, [counted("refund")])
    call = call("call_1", "refund")

    %Call{state: :done, result: first} = ToolRunner.execute(call, run)
    assert_received {:ran, "refund"}

    assert %Call{state: :done, result: ^first} = ToolRunner.execute(call, run)
    refute_received {:ran, "refund"}

    assert_received %Bus.Event{
      payload: %Bus.ToolReplayed{
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

    :ok = Ledger.claim(store(), Ledger.Key.of(run, call), call: call)

    assert %Call{state: :waiting, asks: [%Call.Ask{by: :doubt, prompt: prompt}]} =
             waiting = ToolRunner.execute(call, run)

    assert prompt =~ "may already have done what it does"
    refute_received {:ran, "refund"}

    assert %Call{state: :done} = waiting |> Call.approve() |> ToolRunner.execute(run)

    assert_received {:ran, "refund"}

    assert {:ok, %Ledger.Entry{result: {:ok, _}}} =
             Ledger.fetch(store(), Ledger.Key.of(run, call))
  end

  test "a call claimed and never settled runs again under its key where its tool says it may",
       %{agent_id: agent_id} do
    run = run(agent_id, [Rerunnable])
    call = call("call_1", "refund")

    :ok = Ledger.claim(store(), Ledger.Key.of(run, call), call: call)

    assert %Call{id: "call_1", state: :done} = ToolRunner.execute(call, run)

    key = Ledger.Key.idempotency(run, call)
    assert_received {:ran, "refund", ^key}

    assert {:ok, %Ledger.Entry{result: {:ok, %{"refunded" => true}}}} =
             Ledger.fetch(store(), Ledger.Key.of(run, call))
  end

  test "approving what a hook asked runs nothing the ledger holds as begun", %{
    agent_id: agent_id
  } do
    run = run(agent_id, [counted("deploy")])
    call = call("call_1", "deploy")

    :ok = Ledger.claim(store(), Ledger.Key.of(run, call), call: call)

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
             Ledger.fetch(store(), Ledger.Key.of(run, call))
  end

  test "a call the ledger cannot answer for does not run", %{agent_id: agent_id} do
    run = run(agent_id, [counted("refund")], host(store: %Unwritable{}))
    call = call("call_1", "refund")

    assert %Call{id: "call_1", state: :done} = ToolRunner.execute(call, run)
    refute_received {:ran, "refund"}

    assert_received %Bus.Event{
      payload: %Bus.ToolDenied{call_id: "call_1", name: "refund", reason: reason}
    }

    assert reason =~ "could not record this call before running it"
  end

  test "a store that raises as a call settles answers with what it returned, its claim pending",
       %{agent_id: agent_id} do
    run = run(agent_id, [counted("refund")], host(store: %Unsettling{store: store()}))
    call = call("call_1", "refund")

    assert %Call{state: :done, result: {:ok, %{"done" => true}}} = ToolRunner.execute(call, run)
    assert_received {:ran, "refund"}

    assert {:ok, %Ledger.Entry{result: nil}} = Ledger.fetch(store(), Ledger.Key.of(run, call))
  end

  describe "refusing a call" do
    test "that nothing began is a plain refusal", %{agent_id: agent_id} do
      run = run(agent_id, [counted("deploy")])

      assert %Call{state: :done} =
               ToolRunner.refuse(call("call_1", "deploy"), run, "Not today.")

      assert_received %Bus.Event{
        payload: %Bus.ToolDenied{call_id: "call_1", name: "deploy", reason: "Not today."}
      }
    end

    test "that ran answers with what it returned", %{agent_id: agent_id} do
      run = run(agent_id, [counted("deploy")])
      call = call("call_1", "deploy")
      %Call{state: :done, result: ran} = ToolRunner.execute(call, run)

      assert %Call{state: :done, result: ^ran} = ToolRunner.refuse(call, run, "Not today.")

      assert_received %Bus.Event{
        payload: %Bus.ToolReplayed{call_id: "call_1", name: "deploy", result: {:ok, _result}}
      }

      refute_received %Bus.Event{payload: %Bus.ToolDenied{call_id: "call_1", name: "deploy"}}
    end

    test "that began and never finished tells the model it may have run", %{agent_id: agent_id} do
      run = run(agent_id, [counted("deploy")])
      call = call("call_1", "deploy")

      :ok = Ledger.claim(store(), Ledger.Key.of(run, call), call: call)

      ToolRunner.refuse(call, run, "Not today.")

      assert_received %Bus.Event{
        payload: %Bus.ToolDenied{call_id: "call_1", name: "deploy", reason: reason}
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
             Ledger.forget(store(), agent_id, trace: turn.source.trace.trace_id)

    assert :error =
             Ledger.fetch(store(), Ledger.Key.of(Run.batch(turn, 0), call))

    assert :error =
             Ledger.fetch(store(), Ledger.Key.of(Run.batch(turn, 1), call))

    assert {:ok, _entry} =
             Ledger.fetch(store(), Ledger.Key.of(other, call))
  end

  test "idempotency_key/2 names one call in one turn", %{agent_id: agent_id} do
    run = run(agent_id, [])
    key = Ledger.Key.idempotency(run, call("call_1", "refund"))

    assert key == "#{Wardrik.AgentID.resource(agent_id)}//#{run.source.trace.trace_id}/call_1"
    refute key == Ledger.Key.idempotency(run(agent_id, []), call("call_1", "refund"))
  end
end
