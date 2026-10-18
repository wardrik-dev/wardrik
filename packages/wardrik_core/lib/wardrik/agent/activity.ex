defmodule Wardrik.Agent.Activity do
  @moduledoc """
  What an agent is doing now, since when, and how many messages wait behind
  it, folded from its events.

  What it is doing is the payload of the event that set it, so a surface
  renders it by matching the payload it knows: a `Wardrik.Event.ModelStarted`
  while it asks the model, a `Wardrik.Event.ModelRetrying` while it waits to
  ask again, a `Wardrik.Event.SpanStarted` while a span runs, such as
  `"compacting history"`, a `Wardrik.Event.TurnParked` while it waits on a
  person, and every tool call running, as a list of their
  `Wardrik.Event.ToolStarted`s. Between turns it is `:idle`.

      activity = Enum.reduce(events, activity, &Wardrik.Agent.Activity.fold(&2, &1))

  The last event that says what it is doing wins, and a turn ending sets it
  idle. A tool call ending takes it off the calls running, and the one that
  ends last is what it did last. Deltas, progress and the rest change
  nothing. `since` is when what it is doing began, as `Wardrik.Event`'s
  `at`.

  `Wardrik.Agent` folds its own events and announces each change as
  `Wardrik.Event.ActivityChanged`. The words are a
  `Wardrik.Agent.Activity.Presenter`'s.
  """

  alias Wardrik.Event

  @enforce_keys [:doing, :since]
  defstruct [:doing, :since, pending: 0]

  @typedoc """
  What it is doing: `:idle`, the tool calls running, oldest first, or the
  payload of the event that set it.
  """
  @type doing() ::
          :idle
          | [Event.ToolStarted.t()]
          | Event.TurnStarted.t()
          | Event.TurnResumed.t()
          | Event.TurnParked.t()
          | Event.ModelStarted.t()
          | Event.ModelRetrying.t()
          | Event.SpanStarted.t()
          | Event.ToolFinished.t()
          | Event.ToolDenied.t()
          | Event.ToolReplayed.t()

  @typedoc "What it is doing, since when in microseconds of system time, and how many messages wait."
  @type t() :: %__MODULE__{doing: doing(), since: integer(), pending: non_neg_integer()}

  @salient [
    Event.TurnStarted,
    Event.TurnResumed,
    Event.TurnParked,
    Event.ModelStarted,
    Event.ModelRetrying,
    Event.SpanStarted
  ]
  @ended [Event.TurnFinished, Event.TurnFailed, Event.TurnInterrupted]
  @settled [Event.ToolFinished, Event.ToolDenied, Event.ToolReplayed]

  @doc "The activity after `event`."
  @spec fold(t(), Event.t()) :: t()
  def fold(%__MODULE__{doing: current} = activity, %Event{payload: payload, at: at}) do
    activity = %{activity | pending: max(activity.pending + queued(payload), 0)}

    case doing(current, payload) do
      ^current -> activity
      doing -> %{activity | doing: doing, since: at}
    end
  end

  defp queued(%Event.MessageQueued{}), do: 1
  defp queued(%Event.TurnStarted{messages: messages}), do: -length(messages)
  defp queued(%Event.TurnInterrupted{stats: stats}), do: -stats.dropped
  defp queued(_payload), do: 0

  defp doing(_doing, %kind{}) when kind in @ended, do: :idle
  defp doing([_ | _] = calls, %Event.ToolStarted{} = call), do: calls ++ [call]
  defp doing(_doing, %Event.ToolStarted{} = call), do: [call]

  defp doing([_ | _] = calls, %kind{call_id: id} = ended) when kind in @settled do
    case Enum.reject(calls, &(&1.call_id == id)) do
      [] -> ended
      running -> running
    end
  end

  defp doing(_doing, %kind{} = payload) when kind in @salient or kind in @settled, do: payload
  defp doing(doing, _payload), do: doing
end
