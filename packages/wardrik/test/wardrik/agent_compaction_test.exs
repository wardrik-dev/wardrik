defmodule Wardrik.AgentCompactionTest do
  use ExUnit.Case, async: false
  use Mimic

  alias ReqLLM.Context
  alias Wardrik.Agent
  alias Wardrik.Agent.Message
  alias Wardrik.Agent.State
  alias Wardrik.Agent.State.Compacting
  alias Wardrik.Compaction
  alias Wardrik.Event
  alias Wardrik.LLM.Config
  alias Wardrik.Test.AgentRunners
  alias Wardrik.Test.LLMStub

  setup :set_mimic_global
  setup :verify_on_exit!

  defp long(label), do: String.pad_trailing(label, 400, ".")

  defp history do
    Context.new([
      Context.user(long("first question")),
      Context.assistant(long("first answer")),
      Context.user(long("second question")),
      Context.assistant(long("second answer"))
    ])
  end

  defp config, do: Config.new(compaction: Compaction.new(window: 400, at: 0.6, keep: 0.5))

  defp start(opts) do
    key = Wardrik.Test.Fleet.key("compact")

    {^key, agent} =
      Wardrik.Test.Fleet.start_agent([config: config(), context: history()] ++ opts, key)

    :ok = Event.Bus.subscribe(key)
    {key, agent}
  end

  test "an outgrown history is summarised before the next turn, which runs on the summary" do
    stub(ReqLLM, :generate_text, fn _model, _context, _opts ->
      {:ok, LLMStub.final_answer("Two questions were asked and answered.")}
    end)

    {_key, agent} = start(runner: {AgentRunners, :echo, [self(), "third answer"]})
    Agent.ask(agent, "third question")

    assert_receive %Event{
                     payload: {:context_compacted, %{messages_before: 4, messages_after: 4}}
                   },
                   5_000

    assert_receive {:turn,
                    [
                      {:user, summary},
                      {:assistant, _ack},
                      {:user, _second},
                      {:assistant, _},
                      {:user, "third question"}
                    ]},
                   5_000

    assert summary =~ "Two questions were asked and answered."
    assert_receive %Event{payload: {:turn_finished, _messages}}
  end

  test "a summary that cannot be made leaves the history, and the turn runs regardless" do
    stub(ReqLLM, :generate_text, fn _model, _context, _opts -> {:error, :timeout} end)

    {_key, agent} = start(runner: {AgentRunners, :echo, [self(), "third answer"]})
    Agent.ask(agent, "third question")

    assert_receive {:turn, turn}, 5_000
    assert [_, _, _, _, _] = turn
    refute_received %Event{payload: {:context_compacted, _stats}}
  end

  describe "the state" do
    defp due, do: State.new([config: config(), context: history()], "acme/@jon/assistant")
    defp task, do: %Task{pid: self(), ref: make_ref(), owner: self(), mfa: {__MODULE__, :none, 0}}

    test "take/1 compacts first when the history is due, and not with nothing to do" do
      assert :none = State.take(due())
      {state, _effects} = State.queue(due(), Message.new("next"))
      assert {:compact, _scope, ^state} = State.take(state)
    end

    test "a compaction at rest comes back owed where a turn was, and interrupting it stops it" do
      state = %{due() | mode: :owed} |> State.compacting(task(), System.monotonic_time())
      assert %State{mode: %Compacting{owed: true}} = state
      assert %State{mode: :owed} = state |> State.dump() |> State.load()

      assert {%State{mode: :idle, compaction_settled: true},
              [{:shutdown, _task}, {:emit, _source, {:turn_interrupted, _}}]} =
               State.interrupt(state)
    end

    test "no compaction runs twice before the turn, whatever the first managed" do
      {state, _effects} = State.queue(due(), Message.new("next"))

      for result <- [{:error, :timeout}, {:ok, history(), %{}}] do
        {compacted, _effects} =
          state
          |> State.compacting(task(), System.monotonic_time())
          |> State.compacted(result)

        assert {:run, [%Message{text: "next"}], %State{compaction_settled: false}} =
                 State.take(compacted)
      end
    end
  end
end
