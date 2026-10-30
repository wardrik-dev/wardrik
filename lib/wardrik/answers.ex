defmodule Wardrik.Answers do
  @moduledoc """
  Follows the run that answers a message, through the agent's log.

  It subscribes before sending the message, so it misses nothing.
  """

  alias Wardrik.Instance
  alias Wardrik.Operations.Types
  alias Wardrik.Reply
  alias Wardrik.Scope

  @ended ~w(wardrik.run.failed wardrik.run.cancelled wardrik.run.deadline_exceeded)
  @timeout :timer.minutes(10)

  @doc """
  Sends `input` to `agent`, and returns a stream of its answer.

  The stream yields `{:text, chunk}` as text arrives, then one of:

    * `{:done, %Wardrik.Reply{}}` - the run completed.
    * `{:waiting, interrupts}` - the run waits on a person.
    * `{:failed, reason}` - the run failed, was cancelled, or timed out.

  ## Options

    * `:timeout` - milliseconds to wait for each event. 10 minutes unless set.
  """
  @spec follow(Scope.t(), String.t() | struct(), term(), keyword()) :: Enumerable.t()
  def follow(scope, agent, input, opts) do
    id = Types.path(agent)
    timeout = Keyword.get(opts, :timeout, @timeout)

    Stream.resource(
      fn -> started(scope, id, agent, input) end,
      &next(&1, timeout),
      &stopped/1
    )
  end

  defp started(%Scope{wardrik: instance} = scope, id, agent, input) do
    events = instance |> Instance.fetch!() |> Wardrik.events()
    {:ok, _page} = allowed(Wardrik.Agent.events(scope, agent, limit: 1))
    :ok = WardrikEvents.subscribe(events, [id])

    case Wardrik.Agent.ask(scope, agent, input) do
      {:ok, message} ->
        %{events: events, agent: id, message: message.id, run: nil, text: [], done: false}

      {:error, error} ->
        :ok = WardrikEvents.unsubscribe(events, [id])
        raise error
    end
  end

  defp allowed({:ok, page}), do: {:ok, page}
  defp allowed({:error, error}), do: raise(error)

  defp next(%{done: true} = state, _timeout), do: {:halt, state}

  defp next(%{agent: agent} = state, timeout) do
    receive do
      {WardrikEvents, ^agent, event} -> seen(event, state)
    after
      timeout -> {[{:failed, :timeout}], %{state | done: true}}
    end
  end

  defp seen(%{"type" => "wardrik.run.started", "data" => %{"run" => run}}, %{run: nil} = state) do
    if state.message in Map.get(run, "message_ids", []),
      do: {[], %{state | run: run["id"]}},
      else: {[], state}
  end

  defp seen(event, %{run: run} = state) when is_binary(run) do
    if trace(event) == run, do: ours(event, state), else: {[], state}
  end

  defp seen(_event, state), do: {[], state}

  defp ours(%{"type" => "wardrik.message.delta", "data" => %{"delta" => text}}, state),
    do: {[{:text, text}], %{state | text: [state.text | text]}}

  defp ours(%{"type" => "wardrik.run.completed"}, state) do
    reply = %Reply{message: state.message, run: state.run, text: IO.iodata_to_binary(state.text)}
    {[{:done, reply}], %{state | done: true}}
  end

  defp ours(
         %{"type" => "wardrik.run.interrupted", "data" => %{"interrupts" => interrupts}},
         state
       ),
       do:
         {[{:waiting, Enum.map(interrupts, &Wardrik.Interrupt.from_json/1)}],
          %{state | done: true}}

  defp ours(%{"type" => type, "data" => data}, state) when type in @ended,
    do: {[{:failed, Map.get(data, "error", type)}], %{state | done: true}}

  defp ours(_event, state), do: {[], state}

  defp stopped(%{events: events, agent: agent}) do
    :ok = WardrikEvents.unsubscribe(events, [agent])
    flush(agent)
  end

  defp flush(agent) do
    receive do
      {WardrikEvents, ^agent, _event} -> flush(agent)
    after
      0 -> :ok
    end
  end

  defp trace(%{"traceparent" => "00-" <> rest}), do: rest |> String.split("-", parts: 2) |> hd()
  defp trace(_event), do: nil
end
