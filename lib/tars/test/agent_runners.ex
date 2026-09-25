defmodule Tars.Test.AgentRunners do
  @moduledoc """
  Turn runners and resumers for driving `Tars.Agent` without a model.

  An agent's runner is an MFA, so these are named functions taking their own
  arguments first and the turn's scope and context last.
  """

  alias ReqLLM.Context
  alias Tars.LLM.Message
  alias Tars.LLM.Turn.Parked

  @doc "Reports the context it was handed, then answers immediately."
  def echo(test_pid, reply, _scope, context) do
    send(test_pid, {:turn, snapshot(context)})
    {:ok, [Context.assistant(reply)]}
  end

  @doc "Hands back its own pid and blocks until released."
  def blocking(test_pid, reply, _scope, context) do
    send(test_pid, {:turn, snapshot(context), self()})
    receive do: (:release -> :ok)
    {:ok, [Context.assistant(reply)]}
  end

  @doc "Yields the moment it is asked to."
  def yielding(test_pid, _scope, _context) do
    send(test_pid, {:running, self()})

    receive do
      :yield -> send(test_pid, :yielded)
    after
      1_000 -> send(test_pid, :never_yielded)
    end

    {:ok, [Context.assistant("yielded")]}
  end

  @doc "Streams until interrupted."
  def streaming(test_pid, _scope, _context) do
    send(test_pid, {:running, self()})

    receive do
      :interrupt -> {:ok, [Context.assistant("half a th")]}
    after
      1_000 -> {:ok, [Context.assistant("never interrupted")]}
    end
  end

  @doc "Never answers and never reads its mailbox, so only a kill ends it."
  def deaf(test_pid, _scope, _context) do
    send(test_pid, {:running, self()})
    receive(do: (:never -> :ok))
  end

  @doc "Raises when the last message is `trigger`, and otherwise answers."
  def crashing(test_pid, trigger, _scope, context) do
    send(test_pid, {:turn, snapshot(context)})
    if Message.text(List.last(context.messages)) == trigger, do: raise("kaboom")
    {:ok, [Context.assistant("ok")]}
  end

  @doc """
  Delegates one task named `name`, announcing it as `Tars.Subagent` would,
  and holds it until released; then answers.
  """
  def delegating(test_pid, name, scope, _context) do
    Tars.Scope.span(scope, name, fn branch ->
      Tars.Event.emit(branch.source, {:delegation_started, "look into #{name}"})
      send(test_pid, {:delegating, self()})
      receive do: (:release -> :ok)
      Tars.Event.emit(branch.source, {:delegation_finished, {:ok, "found #{name}"}, 5})
      :ok
    end)

    {:ok, [Context.assistant("done")]}
  end

  @doc "Fails every turn with `reason`."
  def failing(reason, _scope, _context), do: {:error, reason}

  @doc "Emits on the scope it was given before answering."
  def emitting(text, scope, _context) do
    Tars.Event.emit(scope.source, {:result, text})
    {:ok, [Context.assistant("ok")]}
  end

  @doc "Reports the scope it was given, then answers."
  def reporting(test_pid, scope, _context) do
    send(test_pid, {:scope, scope})
    {:ok, [Context.assistant("ok")]}
  end

  @doc "Parks on a single call, so the waiting path runs without a hook."
  def parking(test_pid, call_id, _scope, _context) do
    send(test_pid, :asked)
    {:parked, parked_turn(call_id)}
  end

  @doc "Reports the decisions it was answered with, then returns `result`."
  def resuming(test_pid, result, _scope, _parked, decisions) do
    send(test_pid, {:resumed, decisions})
    result
  end

  @doc "Hands the agent a checkpoint the way a turn does, tells the test, and blocks."
  def checkpointing(test_pid, scope, context) do
    :ok = GenServer.call(scope.journal, {:checkpoint, checkpoint(context)})
    send(test_pid, {:checkpointed, self()})

    receive do
      :release -> {:ok, []}
    end
  end

  @doc "Reports the checkpoint it was asked to replay from, then returns `result`."
  def replaying(test_pid, result, _scope, checkpoint) do
    send(test_pid, {:replayed, checkpoint})
    result
  end

  @doc "A checkpoint of a batch asking for one call to `deploy`."
  def checkpoint(context \\ Context.new()) do
    call = ReqLLM.ToolCall.new("call_1", "deploy", "{}")

    %Tars.LLM.Turn.Checkpoint{
      context: context,
      response: %ReqLLM.Response{
        id: "r",
        model: "m",
        context: context,
        message: Context.assistant("", tool_calls: [call]),
        finish_reason: :tool_calls
      },
      acc: [],
      remaining: 5
    }
  end

  @doc "A turn parked on one call to `deploy`."
  @spec parked_turn(String.t()) :: Parked.t()
  def parked_turn(call_id \\ "call_1") do
    call = %{id: call_id, name: "deploy", arguments: %{}}

    %Parked{
      context: Context.new(),
      response: %ReqLLM.Response{
        id: "r",
        model: "test",
        context: Context.new(),
        finish_reason: :tool_calls
      },
      outcomes: [waiting(call, "This ships to production.")],
      acc: [],
      remaining: 5,
      revision: Tars.Hook.revision([])
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
