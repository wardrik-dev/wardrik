defmodule Wardrik.AgentCompactionTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Wardrik.Agent
  alias Wardrik.Agent.Message
  alias Wardrik.Agent.State
  alias Wardrik.Compaction
  alias Wardrik.Conversation
  alias Wardrik.Conversation.Assistant
  alias Wardrik.Conversation.User
  alias Wardrik.Event
  alias Wardrik.LLM.Config
  alias Wardrik.LLM.Error
  alias Wardrik.Test.AgentRunners
  alias Wardrik.Test.LLM

  defp long(label), do: String.pad_trailing(label, 400, ".")

  defp history do
    Conversation.new([
      User.new(long("first question")),
      Assistant.new(long("first answer")),
      User.new(long("second question")),
      Assistant.new(long("second answer"))
    ])
  end

  defp config,
    do: Config.new(history: Compaction.new(window: 400, at: 0.6, keep: 0.5))

  defp start(opts) do
    key = Wardrik.Test.Fleet.id("compact")

    {^key, agent} =
      Wardrik.Test.Fleet.start_agent(
        Keyword.merge([config: config(), history: history()], opts),
        key
      )

    :ok = Event.Bus.subscribe(key)
    {key, agent}
  end

  test "an outgrown history is summarised as the turn begins, which runs on it, and the agent keeps it" do
    LLM.stream(Wardrik.Test.llm(), [LLM.final_answer("Two questions were asked and answered.")])

    {_key, agent} = start(runner: {AgentRunners, :echo, [self(), "third answer"]})
    Agent.ask(agent, "third question")

    compacting = %Event.SpanStarted{name: "compacting history"}
    assert_receive %Event{payload: ^compacting}, 5_000
    assert_receive %Event{payload: %Event.ActivityChanged{activity: %{doing: ^compacting}}}

    assert_receive %Event{
                     payload: %Event.ContextCompacted{
                       stats: %{messages_before: 4, messages_after: 4}
                     }
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
    assert_receive %Event{payload: %Event.TurnFinished{}}

    assert [kept | _rest] = agent |> Agent.history() |> Conversation.to_list()
    assert Conversation.text(kept) =~ "Two questions were asked and answered."
  end

  test "interrupting a summary interrupts the turn it began" do
    test = self()

    LLM.answering(Wardrik.Test.llm(), fn _asked ->
      send(test, :summarising)

      receive do
        :never -> LLM.final_answer("never")
      end
    end)

    {_key, agent} = start(grace: 50, runner: {AgentRunners, :echo, [self(), "third answer"]})
    Agent.ask(agent, "third question")

    assert_receive :summarising, 5_000
    :ok = Agent.interrupt(agent)

    assert_receive %Event{payload: %Event.TurnInterrupted{stats: %{resolution: :killed}}}, 5_000
    refute_received {:turn, _turn}
  end

  test "a summary that cannot be made leaves the history, and the turn runs regardless" do
    LLM.stream(Wardrik.Test.llm(), [%Error{message: "timeout"}])

    {_key, agent} = start(runner: {AgentRunners, :echo, [self(), "third answer"]})
    Agent.ask(agent, "third question")

    assert_receive {:turn, turn}, 5_000
    assert [_, _, _, _, _] = turn
    refute_received %Event{payload: %Event.ContextCompacted{}}
  end

  defmodule Broken do
    defstruct []

    defimpl Wardrik.History do
      def prepare(_broken, _history, _opts), do: raise("the store is down")
    end
  end

  test "a history that raises fails the turn it began" do
    capture_log(fn ->
      {_key, agent} =
        start(
          config: Config.new(history: %Broken{}),
          runner: {AgentRunners, :echo, [self(), "third answer"]}
        )

      Agent.ask(agent, "third question")

      assert_receive %Event{payload: %Event.TurnFailed{}}, 5_000
      refute_received {:turn, _turn}
    end)
  end

  describe "the state" do
    defp idle,
      do:
        State.new(
          [config: config(), history: history()],
          Wardrik.AgentID.parse!("acme/@jon/assistant")
        )

    defp task, do: %Task{pid: self(), ref: make_ref(), owner: self(), mfa: {__MODULE__, :none, 0}}

    test "take/1 runs the turn on whatever the history holds, and nothing with nothing to do" do
      assert :none = State.take(idle())
      {state, _effects} = State.queue(idle(), Message.new("next"))
      assert {:run, _run, [%Message{text: "next"}], _state} = State.take(state)
    end

    test "kept/3 takes the history the running turn kept, and refuses any other process" do
      run = State.turn_run(idle(), nil)
      running = State.started(idle(), task(), run, history(), System.monotonic_time())
      kept = Conversation.new([User.new("summary")])

      assert {:ok, %State{history: ^kept}} = State.kept(running, self(), kept)
      assert State.kept(running, spawn(fn -> :ok end), kept) == :stale
      assert State.kept(idle(), self(), kept) == :stale
    end
  end
end
