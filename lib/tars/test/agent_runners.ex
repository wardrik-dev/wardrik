defmodule Tars.Test.AgentRunners do
  @moduledoc """
  Turn runners and resumers for driving `Tars.Agent` without a model.

  An agent's runner is an MFA, so these are named functions taking their own
  arguments first and the `Tars.LLM.Turn` last, and handing the turn back.
  """

  alias ReqLLM.Context
  alias Tars.LLM.Message
  alias Tars.LLM.Turn

  @doc "Reports the context it was handed, then answers immediately."
  def echo(test_pid, reply, %Turn{} = turn) do
    send(test_pid, {:turn, snapshot(turn.context)})
    Turn.done(turn, [Context.assistant(reply)])
  end

  @doc "Hands back its own pid and blocks until released."
  def blocking(test_pid, reply, %Turn{} = turn) do
    send(test_pid, {:turn, snapshot(turn.context), self()})
    receive do: (:release -> :ok)
    Turn.done(turn, [Context.assistant(reply)])
  end

  @doc "Yields the moment it is asked to."
  def yielding(test_pid, %Turn{} = turn) do
    send(test_pid, {:running, self()})

    receive do
      :yield -> send(test_pid, :yielded)
    after
      1_000 -> send(test_pid, :never_yielded)
    end

    Turn.done(turn, [Context.assistant("yielded")])
  end

  @doc "Streams until interrupted."
  def streaming(test_pid, %Turn{} = turn) do
    send(test_pid, {:running, self()})

    receive do
      :interrupt -> Turn.done(turn, [Context.assistant("half a th")])
    after
      1_000 -> Turn.done(turn, [Context.assistant("never interrupted")])
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
    if Message.text(List.last(context.messages)) == trigger, do: raise("kaboom")
    Turn.done(turn, [Context.assistant("ok")])
  end

  @doc """
  Delegates one task named `name`, announcing it as `Tars.Subagent` would,
  and holds it until released; then answers.
  """
  def delegating(test_pid, name, %Turn{scope: scope} = turn) do
    Tars.Scope.span(scope, name, fn branch ->
      Tars.Event.emit(branch.source, {:delegation_started, "look into #{name}"})
      send(test_pid, {:delegating, self()})
      receive do: (:release -> :ok)
      Tars.Event.emit(branch.source, {:delegation_finished, {:ok, "found #{name}"}, 5})
      :ok
    end)

    Turn.done(turn, [Context.assistant("done")])
  end

  @doc "Fails every turn with `reason`."
  def failing(reason, %Turn{} = turn), do: Turn.fail(turn, reason)

  @doc "Emits on the scope it was given before answering."
  def emitting(text, %Turn{scope: scope} = turn) do
    Tars.Event.emit(scope.source, {:result, text})
    Turn.done(turn, [Context.assistant("ok")])
  end

  @doc "Reports the scope it was given, then answers."
  def reporting(test_pid, %Turn{scope: scope} = turn) do
    send(test_pid, {:scope, scope})
    Turn.done(turn, [Context.assistant("ok")])
  end

  @doc "Waits on a single call, so the waiting path runs without a hook."
  def parking(test_pid, call_id, %Turn{scope: scope}) do
    send(test_pid, :asked)
    Turn.under(parked_turn(call_id), scope)
  end

  @doc """
  Tells the test it was asked, then comes back waiting on a person to
  authorize at `link`, as a tool connecting an account parks.
  """
  def connecting(test_pid, call_id, link, %Turn{scope: scope}) do
    send(test_pid, :asked)
    %Turn{calls: [waiting]} = turn = parked_turn(call_id)
    prompt = "To connect github, open its authorization link."
    parked = Tars.Call.park(%{waiting | asks: []}, prompt, link: link)
    Turn.under(%{turn | calls: [parked]}, scope)
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

  @doc "Hands the agent the turn before a batch, as a turn does, tells the test, and blocks."
  def checkpointing(test_pid, %Turn{scope: scope, context: context} = turn) do
    :ok = GenServer.call(scope.journal, {:checkpoint, checkpoint(context)})
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
  defp came_to(turn, {:parked, %Turn{} = parked}), do: Turn.under(parked, turn.scope)

  @doc "A turn written down before a batch asking for one call to `deploy`."
  def checkpoint(context \\ Context.new()) do
    call = ReqLLM.ToolCall.new("call_1", "deploy", "{}")

    %Turn{
      context: context,
      response: %ReqLLM.Response{
        id: "r",
        model: "m",
        context: context,
        message: Context.assistant("", tool_calls: [call]),
        finish_reason: :tool_calls
      },
      remaining: 5
    }
  end

  @doc "A turn written down, waiting on one call to `deploy`."
  @spec parked_turn(String.t()) :: Turn.t()
  def parked_turn(call_id \\ "call_1") do
    call = %{id: call_id, name: "deploy", arguments: %{}}

    %Turn{
      context: Context.new(),
      response: %ReqLLM.Response{
        id: "r",
        model: "test",
        context: Context.new(),
        finish_reason: :tool_calls
      },
      calls: [waiting(call, "This ships to production.")],
      remaining: 5,
      revision: Tars.Hook.revision([]),
      state: :waiting
    }
  end

  @doc """
  `call` waiting on a person, asked `prompt` by a hook named `careful`, as a
  turn holds it.
  """
  @spec waiting(Tars.Tool.call(), String.t()) :: Tars.Call.t()
  def waiting(call, prompt) do
    %{
      Tars.Call.tool(call)
      | state: :waiting,
        asks: [%Tars.Call.Ask{by: "careful", prompt: prompt}]
    }
  end

  @doc "The roles and text of a context, for asserting on what a turn was handed."
  def snapshot(context), do: Enum.map(context.messages, &{&1.role, Message.text(&1)})
end
