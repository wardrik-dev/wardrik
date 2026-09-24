defmodule Tars.LLM.TurnJournalTest do
  use ExUnit.Case, async: true
  use Mimic

  alias ReqLLM.Context
  alias Tars.Event
  alias Tars.Ledger
  alias Tars.LLM
  alias Tars.LLM.Turn.Checkpoint
  alias Tars.Scope
  alias Tars.Test.LLMStub

  setup :verify_on_exit!

  setup do
    agent_id = Tars.Test.Fleet.key()
    :ok = Event.Bus.subscribe(agent_id)
    {:ok, agent_id: agent_id}
  end

  defp refund_tool(test_pid) do
    ReqLLM.Tool.new!(
      name: "refund",
      description: "Refunds an order.",
      parameter_schema: [],
      callback: fn _args ->
        send(test_pid, :refunded)
        {:ok, %{"refunded" => true}}
      end
    )
  end

  defp scope(agent_id, opts) do
    LLM.Config.new(tools: [refund_tool(self())])
    |> Scope.root(agent_id, [name: "turn", ledger: Ledger.Store] ++ opts)
  end

  defp run_async(scope) do
    Task.async(fn -> LLM.Turn.run(scope, Context.new([Context.user("refund it")])) end)
  end

  test "hands the journal each batch before any of it runs", %{agent_id: agent_id} do
    LLMStub.stream([LLMStub.tool_call("call_1", "refund", %{}), LLMStub.final_answer("done")])
    task = run_async(scope(agent_id, journal: self()))

    assert_receive {:"$gen_call", from, {:checkpoint, %Checkpoint{} = checkpoint}}
    assert Checkpoint.call_ids(checkpoint) == ["call_1"]
    refute_received :refunded

    GenServer.reply(from, :ok)

    assert_receive :refunded
    assert {:ok, _messages} = Task.await(task)
  end

  test "a journal that does not answer ends the turn before anything runs", %{agent_id: agent_id} do
    LLMStub.stream([LLMStub.tool_call("call_1", "refund", %{})])
    task = run_async(scope(agent_id, journal: self()))

    assert_receive {:"$gen_call", from, {:checkpoint, _checkpoint}}
    GenServer.reply(from, {:error, :disk_full})

    assert {:error, {:checkpoint_failed, :disk_full}} = Task.await(task)
    refute_received :refunded
  end

  test "a final answer is not handed to the journal", %{agent_id: agent_id} do
    LLMStub.stream([LLMStub.final_answer("done")])
    task = run_async(scope(agent_id, journal: self()))

    assert {:ok, _messages} = Task.await(task)
    refute_received {:"$gen_call", _from, {:checkpoint, _checkpoint}}
  end

  test "replay/2 answers a call that already ran from the ledger, and goes on", %{
    agent_id: agent_id
  } do
    scope = scope(agent_id, [])
    response = LLMStub.tool_call("call_1", "refund", %{})
    [call] = ReqLLM.Response.classify(response).tool_calls
    key = Ledger.key(Scope.batch(scope, 0), call)
    :ok = Ledger.claim(Ledger.Store, key, call)
    :ok = Ledger.settle(Ledger.Store, key, {:ok, %{"refunded" => true}})

    LLMStub.stream([LLMStub.final_answer("Refunded.")])

    checkpoint = %Checkpoint{
      context: Context.new([Context.user("refund it")]),
      response: response,
      acc: [],
      remaining: 5
    }

    assert {:ok, messages} = LLM.Turn.replay(scope, checkpoint)
    refute_received :refunded
    assert_received %Event{payload: {:tool_replayed, "call_1", "refund", {:ok, _result}}}
    assert List.last(messages).role == :assistant
  end

  test "a call a policy asked about, and found to have begun since, is asked about again", %{
    agent_id: agent_id
  } do
    scope = scope(agent_id, [])
    response = LLMStub.tool_call("call_1", "refund", %{})
    [call] = ReqLLM.Response.classify(response).tool_calls
    :ok = Ledger.claim(Ledger.Store, Ledger.key(Scope.batch(scope, 0), call), call)

    parked =
      LLM.Turn.Parked.new(
        Context.new([Context.user("refund it")]),
        response,
        [{:parked, call, "This refunds money."}],
        [],
        5
      )

    assert {:parked, again} = LLM.Turn.resume(scope, parked, %{"call_1" => :approve})
    assert [{%{id: "call_1"}, prompt}] = LLM.Turn.Parked.calls(again)
    assert prompt =~ "may already have done what it does"
    refute_received :refunded

    LLMStub.stream([LLMStub.final_answer("Refunded.")])

    assert {:ok, messages} = LLM.Turn.resume(scope, again, %{"call_1" => :approve})
    assert_received :refunded
    assert List.last(messages).role == :assistant
  end

  test "a call id the model gives again in a later round is another call", %{agent_id: agent_id} do
    LLMStub.stream([
      LLMStub.tool_call("call_0", "refund", %{}),
      LLMStub.tool_call("call_0", "refund", %{}),
      LLMStub.final_answer("Refunded both.")
    ])

    assert {:ok, _messages} =
             LLM.Turn.run(scope(agent_id, []), Context.new([Context.user("refund both")]))

    assert_received :refunded
    assert_received :refunded
  end

  test "a delegation's calls are named apart from those of the turn that made it", %{
    agent_id: agent_id
  } do
    test_pid = self()

    research =
      ReqLLM.Tool.new!(
        name: "research",
        description: "Hands the work to a delegate.",
        parameter_schema: [],
        callback: fn _args ->
          {:ok, answer} = Tars.Subagent.run(Tars.Scope.Context.current(), "refund it")
          {:ok, %{"answer" => answer}}
        end
      )

    LLMStub.stream([
      LLMStub.tool_call("call_0", "research", %{}),
      LLMStub.tool_call("call_0", "refund", %{}),
      LLMStub.final_answer("Refunded."),
      LLMStub.final_answer("Done.")
    ])

    scope =
      LLM.Config.new(tools: [research, refund_tool(test_pid)])
      |> Scope.root(agent_id, name: "turn", ledger: Ledger.Store)

    assert {:ok, _messages} = LLM.Turn.run(scope, Context.new([Context.user("look into it")]))
    assert_received :refunded
  end

  test "a delegation's scope has no journal", %{agent_id: agent_id} do
    assert Scope.child(scope(agent_id, journal: self())).journal == nil
  end
end
