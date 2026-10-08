defmodule Wardrik.AgentCompactionTest do
  use ExUnit.Case, async: false
  use Mimic

  alias ReqLLM.Context
  alias Wardrik.Agent
  alias Wardrik.Agent.Message
  alias Wardrik.Agent.State
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

  defp config,
    do: Config.new(history: {Compaction, Compaction.new(window: 400, at: 0.6, keep: 0.5)})

  defp start(opts) do
    key = Wardrik.Test.Fleet.id("compact")

    {^key, agent} =
      Wardrik.Test.Fleet.start_agent([config: config(), context: history()] ++ opts, key)

    :ok = Event.Bus.subscribe(key)
    {key, agent}
  end

  test "an outgrown history is summarised as the turn begins, which runs on it, and the agent keeps it" do
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

    assert [kept | _rest] = agent |> Agent.get_context() |> Context.to_list()
    assert Wardrik.LLM.Message.text(kept) =~ "Two questions were asked and answered."
  end

  test "interrupting a summary interrupts the turn it began" do
    test = self()

    stub(ReqLLM, :generate_text, fn _model, _context, _opts ->
      send(test, :summarising)

      receive do
        :never -> {:ok, LLMStub.final_answer("never")}
      end
    end)

    {_key, agent} = start(grace: 50, runner: {AgentRunners, :echo, [self(), "third answer"]})
    Agent.ask(agent, "third question")

    assert_receive :summarising, 5_000
    :ok = Agent.interrupt(agent)

    assert_receive %Event{payload: {:turn_interrupted, %{resolution: :killed}}}, 5_000
    refute_received {:turn, _turn}
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
    defp idle,
      do:
        State.new(
          [config: config(), context: history()],
          Wardrik.AgentID.parse!("acme/@jon/assistant")
        )

    defp task, do: %Task{pid: self(), ref: make_ref(), owner: self(), mfa: {__MODULE__, :none, 0}}

    test "take/1 runs the turn on whatever the history holds, and nothing with nothing to do" do
      assert :none = State.take(idle())
      {state, _effects} = State.queue(idle(), Message.new("next"))
      assert {:run, [%Message{text: "next"}], _state} = State.take(state)
    end

    test "kept/3 takes the history the running turn kept, and refuses any other process" do
      scope = State.turn_scope(idle())
      running = State.started(idle(), task(), scope, history(), System.monotonic_time())
      kept = Context.new([Context.user("summary")])

      assert {:ok, %State{context: ^kept}} = State.kept(running, self(), kept)
      assert State.kept(running, spawn(fn -> :ok end), kept) == :stale
      assert State.kept(idle(), self(), kept) == :stale
    end
  end
end
