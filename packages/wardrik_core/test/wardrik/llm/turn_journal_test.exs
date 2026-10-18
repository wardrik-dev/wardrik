defmodule Wardrik.LLM.TurnJournalTest do
  use ExUnit.Case, async: true

  import Wardrik.Test, only: [host: 0]
  use Mimic

  alias ReqLLM.Context
  alias Wardrik.Event
  alias Wardrik.Ledger
  alias Wardrik.LLM
  alias Wardrik.Run
  alias Wardrik.Test.LLMStub

  # A turn run, resumed or replayed through its token, as a turn under
  # `run` is.
  defp turn(run, context), do: run |> LLM.Turn.new(context) |> LLM.Turn.run()

  defp resume(run, turn, decisions),
    do: turn |> LLM.Turn.under(run) |> LLM.Turn.resume(decisions)

  defp replay(run, turn), do: turn |> LLM.Turn.under(run) |> LLM.Turn.replay()

  setup :verify_on_exit!

  setup do
    agent_id = Wardrik.Test.Fleet.id()
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

  defp run(agent_id, opts) do
    LLM.Config.new(tools: [refund_tool(self())])
    |> Run.root(agent_id, [name: "turn", ledger: %Ledger.Store{}, host: host()] ++ opts)
  end

  defp run_async(run) do
    Task.async(fn -> turn(run, Context.new([Context.user("refund it")])) end)
  end

  test "hands the journal each batch before any of it runs", %{agent_id: agent_id} do
    LLMStub.stream([LLMStub.tool_call("call_1", "refund", %{}), LLMStub.final_answer("done")])
    task = run_async(run(agent_id, journal: self()))

    assert_receive {:"$gen_call", from, {:checkpoint, %LLM.Turn{} = checkpoint}}
    assert LLM.Turn.call_ids(checkpoint) == ["call_1"]
    refute_received :refunded

    GenServer.reply(from, :ok)

    assert_receive :refunded
    assert %LLM.Turn{state: :done, messages: _messages} = Task.await(task)
  end

  test "a turn carried on after a lost node has read what it read, and carries its labels still",
       %{
         agent_id: agent_id
       } do
    LLMStub.stream([
      LLMStub.tool_call("call_1", "fetch", %{"url" => "https://example.com"}),
      LLMStub.tool_call("call_2", "deploy", %{"target" => "prod"})
    ])

    rules = [Wardrik.Hook.new("rules", Wardrik.Test.Tools.Rules, allow: ["deploy"])]

    run =
      [tools: [Wardrik.Test.Tools.Fetch, Wardrik.Test.Tools.Deploy]]
      |> LLM.Config.new()
      |> Run.root(agent_id, name: "turn", ledger: %Ledger.Store{}, hooks: rules, host: host())

    journaled = %{run | journal: self()}
    task = Task.async(fn -> turn(journaled, Context.new()) end)

    assert_receive {:"$gen_call", from, {:checkpoint, %LLM.Turn{labels: []}}}
    GenServer.reply(from, :ok)

    # The node is lost as the second batch is written down.
    assert_receive {:"$gen_call", _from,
                    {:checkpoint, %LLM.Turn{labels: ["outside"]} = checkpoint}}

    Task.shutdown(task, :brutal_kill)

    assert %LLM.Turn{state: :waiting} = replayed = replay(run, checkpoint)
    assert [{%{id: "call_2"}, prompt}] = LLM.Turn.waiting(replayed)
    assert prompt =~ "this run has read content from outside"
  end

  test "a journal that does not answer ends the turn before anything runs", %{agent_id: agent_id} do
    LLMStub.stream([LLMStub.tool_call("call_1", "refund", %{})])
    task = run_async(run(agent_id, journal: self()))

    assert_receive {:"$gen_call", from, {:checkpoint, _checkpoint}}
    GenServer.reply(from, {:error, :disk_full})

    assert %LLM.Turn{state: :failed, error: {:checkpoint_failed, :disk_full}} = Task.await(task)
    refute_received :refunded
  end

  test "a final answer is not handed to the journal", %{agent_id: agent_id} do
    LLMStub.stream([LLMStub.final_answer("done")])
    task = run_async(run(agent_id, journal: self()))

    assert %LLM.Turn{state: :done, messages: _messages} = Task.await(task)
    refute_received {:"$gen_call", _from, {:checkpoint, _checkpoint}}
  end

  test "replay/2 answers a call that already ran from the ledger, and goes on", %{
    agent_id: agent_id
  } do
    run = run(agent_id, [])
    response = LLMStub.tool_call("call_1", "refund", %{})
    [call] = ReqLLM.Response.classify(response).tool_calls
    key = Ledger.Key.of(Run.batch(run, 0), call)
    :ok = Ledger.claim(%Ledger.Store{}, key, call: call, store: Wardrik.Test.store())

    :ok =
      Ledger.settle(%Ledger.Store{}, key,
        result: {:ok, %{"refunded" => true}},
        store: Wardrik.Test.store()
      )

    LLMStub.stream([LLMStub.final_answer("Refunded.")])

    checkpoint = %LLM.Turn{
      context: Context.new([Context.user("refund it")]),
      response: response,
      remaining: 5
    }

    assert %LLM.Turn{state: :done, messages: messages} = replay(run, checkpoint)
    refute_received :refunded

    assert_received %Event{
      payload: %Event.ToolReplayed{call_id: "call_1", name: "refund", result: {:ok, _result}}
    }

    assert List.last(messages).role == :assistant
  end

  test "a call a policy asked about, and found to have begun since, is asked about again", %{
    agent_id: agent_id
  } do
    run = run(agent_id, [])
    response = LLMStub.tool_call("call_1", "refund", %{})
    [call] = ReqLLM.Response.classify(response).tool_calls

    :ok =
      Ledger.claim(
        %Ledger.Store{},
        Ledger.Key.of(Run.batch(run, 0), call),
        call: call,
        store: Wardrik.Test.store()
      )

    parked = %LLM.Turn{
      context: Context.new([Context.user("refund it")]),
      response: response,
      calls: [Wardrik.Test.AgentRunners.waiting(call, "This refunds money.")],
      remaining: 5,
      revision: Wardrik.Hook.revision([]),
      state: :waiting
    }

    assert %LLM.Turn{state: :waiting} = again = resume(run, parked, %{"call_1" => :approve})
    assert [{%{id: "call_1"}, prompt}] = LLM.Turn.waiting(again)
    assert prompt =~ "may already have done what it does"
    refute_received :refunded

    LLMStub.stream([LLMStub.final_answer("Refunded.")])

    assert %LLM.Turn{state: :done, messages: messages} =
             resume(run, again, %{"call_1" => :approve})

    assert_received :refunded
    assert List.last(messages).role == :assistant
  end

  test "a call id the model gives again in a later round is another call", %{agent_id: agent_id} do
    LLMStub.stream([
      LLMStub.tool_call("call_0", "refund", %{}),
      LLMStub.tool_call("call_0", "refund", %{}),
      LLMStub.final_answer("Refunded both.")
    ])

    assert %LLM.Turn{state: :done, messages: _messages} =
             turn(run(agent_id, []), Context.new([Context.user("refund both")]))

    assert_received :refunded
    assert_received :refunded
  end

  test "a delegation's calls are named apart from those of the turn that made it", %{
    agent_id: agent_id
  } do
    test_pid = self()

    research =
      Wardrik.Tool.new!(
        name: "research",
        description: "Hands the work to a delegate.",
        parameter_schema: [],
        run: fn _input, context ->
          {:ok, answer} = Wardrik.Subagent.run(context.run, "refund it")
          {:ok, %{"answer" => answer}}
        end
      )

    LLMStub.stream([
      LLMStub.tool_call("call_0", "research", %{}),
      LLMStub.tool_call("call_0", "refund", %{}),
      LLMStub.final_answer("Refunded."),
      LLMStub.final_answer("Done.")
    ])

    run =
      LLM.Config.new(tools: [research, refund_tool(test_pid)])
      |> Run.root(agent_id, name: "turn", ledger: %Ledger.Store{}, host: host())

    assert %LLM.Turn{state: :done, messages: _messages} =
             turn(run, Context.new([Context.user("look into it")]))

    assert_received :refunded
  end

  test "a delegation's run has no journal", %{agent_id: agent_id} do
    assert Run.child(run(agent_id, journal: self())).journal == nil
  end
end
