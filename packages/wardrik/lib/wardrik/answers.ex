defmodule Wardrik.Answers do
  @moduledoc false

  alias Wardrik.Instance
  alias Wardrik.Operations.Types
  alias Wardrik.Reply
  alias Wardrik.Scope

  @ended ~w(wardrik.run.failed wardrik.run.cancelled wardrik.run.deadline_exceeded)
  @timeout :timer.minutes(10)

  @doc """
  Sends `input` to `agent`, and streams `{:text, chunk}`, then `{:done, reply}`,
  `{:waiting, interrupts}` or `{:failed, why}`.

  ## Options

    * `:conversation` - one of the agent's conversations.
    * `:timeout` - milliseconds to wait for each event. 10 minutes unless set.
  """
  @spec follow(Scope.t(), String.t() | struct(), term(), keyword()) :: Enumerable.t()
  def follow(scope, agent, input, opts \\ []) do
    log = {Types.path(agent), opts[:conversation]}
    timeout = Keyword.get(opts, :timeout, @timeout)

    Stream.resource(
      fn -> started(scope, log, input) end,
      &next(&1, timeout),
      &stopped/1
    )
  end

  defp started(%Scope{wardrik: instance} = scope, {agent, conversation} = log, input) do
    events = instance |> Instance.fetch!() |> Wardrik.events()

    {:ok, _page} =
      allowed(Wardrik.Agent.events(scope, agent, [limit: 1], conversation: conversation))

    :ok = Wardrik.EventLog.subscribe(events, [log])

    case Wardrik.Agent.ask(scope, agent, input, conversation: conversation) do
      {:ok, message} ->
        %{events: events, agent: log, message: message.id, run: nil, text: [], done: false}

      {:error, error} ->
        :ok = Wardrik.EventLog.unsubscribe(events, [log])
        raise error
    end
  end

  defp allowed({:ok, page}), do: {:ok, page}
  defp allowed({:error, error}), do: raise(error)

  defp next(%{done: true} = state, _timeout), do: {:halt, state}

  defp next(%{agent: agent} = state, timeout) do
    receive do
      {Wardrik.EventLog, ^agent, event} -> seen(event, state)
    after
      timeout -> {[{:failed, "Nothing came for #{timeout} ms."}], %{state | done: true}}
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
         %{agent: {agent, conversation}} = state
       ) do
    waiting =
      for interrupt <- interrupts,
          do: %{
            Wardrik.Interrupt.from_json(interrupt)
            | agent: agent,
              conversation: conversation
          }

    {[{:waiting, waiting}], %{state | done: true}}
  end

  defp ours(%{"type" => type, "data" => data}, state) when type in @ended,
    do: {[{:failed, why(type, data)}], %{state | done: true}}

  defp ours(_event, state), do: {[], state}

  defp why("wardrik.run.failed", %{"error" => %{"message" => message}}), do: message
  defp why("wardrik.run.failed", _data), do: "It failed."
  defp why("wardrik.run.cancelled", _data), do: "It was cancelled."
  defp why("wardrik.run.deadline_exceeded", _data), do: "It ran past its timeout."

  defp stopped(%{events: events, agent: agent}) do
    :ok = Wardrik.EventLog.unsubscribe(events, [agent])
    flush(agent)
  end

  defp flush(agent) do
    receive do
      {Wardrik.EventLog, ^agent, _event} -> flush(agent)
    after
      0 -> :ok
    end
  end

  defp trace(%{"traceparent" => "00-" <> rest}), do: rest |> String.split("-", parts: 2) |> hd()
  defp trace(_event), do: nil
end
