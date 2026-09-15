defmodule Tars.Test.AgentRunners do
  @moduledoc """
  Turn runners and resumers for driving `Tars.Agent` without a model.

  An agent's runner is an MFA, so these are named functions taking their own
  arguments first and the turn's scope and context last.
  """

  alias ReqLLM.Context
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
    if text(List.last(context.messages)) == trigger, do: raise("kaboom")
    {:ok, [Context.assistant("ok")]}
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

  @doc "Parks on a single call, so the waiting path runs without a policy."
  def parking(test_pid, call_id, _scope, _context) do
    send(test_pid, :asked)
    {:parked, parked_turn(call_id)}
  end

  @doc "Reports the decisions it was answered with, then returns `result`."
  def resuming(test_pid, result, _scope, _parked, decisions) do
    send(test_pid, {:resumed, decisions})
    result
  end

  @doc "A turn parked on one call to `deploy`."
  @spec parked_turn(String.t()) :: Parked.t()
  def parked_turn(call_id \\ "call_1") do
    call = %{id: call_id, name: "deploy", arguments: %{}}

    Parked.new(
      Context.new(),
      %ReqLLM.Response{
        id: "r",
        model: "test",
        context: Context.new(),
        finish_reason: :tool_calls
      },
      [{:parked, call, "This ships to production."}],
      [],
      5
    )
  end

  @doc "The roles and text of a context, for asserting on what a turn was handed."
  def snapshot(context), do: Enum.map(context.messages, &{&1.role, text(&1)})

  defp text(message), do: Tars.LLM.Context.text(message)
end
