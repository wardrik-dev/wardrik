defmodule Wardrik.Test.AgentRunners do
  @moduledoc """
  Turn runners and resumers for driving `Wardrik.Agent` without a model.

  An agent's runner is an MFA, so these are named functions taking their own
  arguments first and the `Wardrik.LLM.Turn` last, and handing the turn back.
  """

  alias Wardrik.Conversation
  alias Wardrik.Conversation.Assistant
  alias Wardrik.Conversation.ToolCall
  alias Wardrik.Event
  alias Wardrik.LLM.Turn

  @doc "Reports the history it was handed, then answers immediately."
  def echo(test_pid, reply, %Turn{} = turn) do
    send(test_pid, {:turn, snapshot(turn.context)})
    Turn.done(turn, [Assistant.new(reply)])
  end

  @doc "Hands back its own pid and blocks until released."
  def blocking(test_pid, reply, %Turn{} = turn) do
    send(test_pid, {:turn, snapshot(turn.context), self()})
    receive do: (:release -> :ok)
    Turn.done(turn, [Assistant.new(reply)])
  end

  @doc "Yields the moment it is asked to."
  def yielding(test_pid, %Turn{} = turn) do
    send(test_pid, {:running, self()})

    receive do
      :yield -> send(test_pid, :yielded)
    after
      1_000 -> send(test_pid, :never_yielded)
    end

    Turn.done(turn, [Assistant.new("yielded")])
  end

  @doc "Streams until interrupted."
  def streaming(test_pid, %Turn{} = turn) do
    send(test_pid, {:running, self()})

    receive do
      :interrupt -> Turn.done(turn, [Assistant.new("half a th")])
    after
      1_000 -> Turn.done(turn, [Assistant.new("never interrupted")])
    end
  end

  @doc "Never answers and never reads its mailbox, so only a kill ends it."
  def deaf(test_pid, %Turn{}) do
    send(test_pid, {:running, self()})
    receive(do: (:never -> :ok))
  end

  @doc "Raises when the last message is `trigger`, and otherwise answers."
  def crashing(test_pid, trigger, %Turn{context: context} = turn) do
    send(test_pid, {:turn, snapshot(context)})
    if Conversation.text(List.last(context.messages)) == trigger, do: raise("kaboom")
    Turn.done(turn, [Assistant.new("ok")])
  end

  @doc """
  Delegates one task named `name`, announcing it as `Wardrik.Subagent` would,
  and holds it until released; then answers.
  """
  def delegating(test_pid, name, %Turn{run: run} = turn) do
    Wardrik.Run.span(run, name, fn branch ->
      Wardrik.Event.emit(branch.source, %Event.DelegationStarted{prompt: "look into #{name}"})
      send(test_pid, {:delegating, self()})
      receive do: (:release -> :ok)

      Wardrik.Event.emit(branch.source, %Event.DelegationFinished{
        outcome: {:ok, "found #{name}"},
        duration_ms: 5
      })

      :ok
    end)

    Turn.done(turn, [Assistant.new("done")])
  end

  @doc "Fails every turn with `reason`."
  def failing(reason, %Turn{} = turn), do: Turn.fail(turn, reason)

  @doc "Emits on the run it was given before answering."
  def emitting(text, %Turn{run: run} = turn) do
    Wardrik.Event.emit(run.source, %Event.Result{text: text})
    Turn.done(turn, [Assistant.new("ok")])
  end

  @doc "Reports the run it was given, then answers."
  def reporting(test_pid, %Turn{run: run} = turn) do
    send(test_pid, {:run, run})
    Turn.done(turn, [Assistant.new("ok")])
  end

  @doc "Waits on a single call, so the waiting path runs without a hook."
  def parking(test_pid, call_id, %Turn{run: run}) do
    send(test_pid, :asked)
    Turn.under(parked_turn(call_id), run)
  end

  @doc """
  Tells the test it was asked, then comes back waiting on a person to
  authorize at `link`, as a tool connecting an account parks; with
  `credential`, `%{ref: ref, owner: owner}`, as the runtime parks a call
  whose tool names a credential the person has yet to connect.
  """
  def connecting(test_pid, call_id, link, %Turn{} = turn),
    do: connecting(test_pid, call_id, link, nil, turn)

  def connecting(test_pid, call_id, link, credential, %Turn{run: run}) do
    send(test_pid, :asked)
    %Turn{calls: [waiting]} = turn = parked_turn(call_id)
    prompt = "To connect github, open its authorization link."
    parked = Wardrik.Call.park(%{waiting | asks: []}, prompt, link: link, credential: credential)
    Turn.under(%{turn | calls: [parked]}, run)
  end

  @doc """
  Reports the decisions it was answered with, then comes to `result`:
  `{:ok, messages}`, `{:error, reason}`, or `{:parked, turn}` for a turn to
  hand back waiting.
  """
  def resuming(test_pid, result, %Turn{} = turn, decisions) do
    send(test_pid, {:resumed, decisions})
    came_to(turn, result)
  end

  @doc """
  Reports the decisions it was answered with and blocks, as a resumed turn
  running its calls does, then comes to `result`, as `resuming/4` does.
  """
  def holding(test_pid, result, %Turn{} = turn, decisions) do
    send(test_pid, {:holding, decisions, self()})
    receive do: (:release -> came_to(turn, result))
  end

  @doc "Hands the agent the turn before a batch, as a turn does, tells the test, and blocks."
  def checkpointing(test_pid, %Turn{run: run, context: context} = turn) do
    :ok = GenServer.call(run.journal, {:checkpoint, checkpoint(context)})
    send(test_pid, {:checkpointed, self()})

    receive do
      :release -> Turn.done(turn)
    end
  end

  @doc "Reports the turn it was asked to replay, then comes to `result`, as `resuming/4` does."
  def replaying(test_pid, result, %Turn{} = turn) do
    send(test_pid, {:replayed, Turn.under(turn, nil)})
    came_to(turn, result)
  end

  defp came_to(turn, {:ok, messages}), do: Turn.done(%{turn | state: :running}, messages)
  defp came_to(turn, {:error, reason}), do: Turn.fail(turn, reason)
  defp came_to(turn, {:parked, %Turn{} = parked}), do: Turn.under(parked, turn.run)

  @doc "A turn written down before a batch asking for one call to `deploy`."
  def checkpoint(context \\ Conversation.new()) do
    %Turn{
      context: context,
      answer: Wardrik.Test.LLM.tool_call("call_1", "deploy", %{}),
      remaining: 5
    }
  end

  @doc "A turn written down, waiting on one call to `deploy`."
  @spec parked_turn(String.t()) :: Turn.t()
  def parked_turn(call_id \\ "call_1") do
    call = %ToolCall{id: call_id, name: "deploy", arguments: %{}}

    %Turn{
      context: Conversation.new(),
      answer: Wardrik.Test.LLM.answer(%Assistant{parts: []}, :tool_calls),
      calls: [waiting(call, "This ships to production.")],
      remaining: 5,
      revision: Wardrik.Hook.revision([]),
      state: :waiting
    }
  end

  @doc """
  `call` waiting on a person, asked `prompt` by a hook named `careful`, as a
  turn holds it.
  """
  @spec waiting(Wardrik.Tool.call(), String.t()) :: Wardrik.Call.t()
  def waiting(call, prompt) do
    %{
      Wardrik.Call.tool(call)
      | state: :waiting,
        asks: [%Wardrik.Call.Ask{by: "careful", prompt: prompt}]
    }
  end

  @doc "The authors and text of a history, for asserting on what a turn was handed."
  def snapshot(context), do: Enum.map(context.messages, &{role(&1), Conversation.text(&1)})

  defp role(%Wardrik.Conversation.User{}), do: :user
  defp role(%Assistant{}), do: :assistant
  defp role(_answer), do: :tool
end
