defmodule Wardrik.Views.Timeline do
  @moduledoc """
  An agent's conversation as a person reads it, kept current as its events arrive.

      {:ok, %Wardrik.Page{events: events}} = Wardrik.Agent.events(scope, "agt_1")
      timeline = Wardrik.Views.Timeline.fold(events)

      {:ok, stream} = Wardrik.Agent.stream_events(scope, "agt_1", after: cursor)

      for {event, _cursor} <- stream, reduce: timeline do
        timeline ->
          timeline = Wardrik.Views.Timeline.apply(timeline, event)
          redraw(Wardrik.Views.Timeline.touched(timeline))
          timeline
      end

  It takes `Wardrik.Event`s, or events as `Wardrik.run/3` and `Wardrik.stream/3` answer them.
  `Wardrik.Agent.timeline/3` answers the same items once, as JSON.

  ## Items

  Each item has an `:id` and a `:kind`:

    * `:user` - a message someone sent. Has `:text`, `:sender` and `:at`.
    * `:run` - the agent's answer. Has `:status`, `:steps` (oldest first), `:model`,
      `:cost_micro_usd`, `:started_at`, `:finished_at`, `:error` and `:interrupts`. `:status` is
      `:running`, `:completed`, `:failed`, `:cancelled` or `:waiting`.

  Each step has an `:id` and a `:type`:

    * `:thinking` and `:text` - have `:text`, and `:live` while it streams.
    * `:tool` - has `:name`, `:arguments`, `:status`, `:result` and `:error`. `:status` is
      `:running`, `:ok`, `:error` or `:denied`.
    * `:subagent` - a task handed to a delegate. Has `:name`, `:prompt`, `:status`, `:tools`, the
      tool calls it made, `:answer` and `:error`. `:status` is `:running`, `:ok` or `:error`.
  """

  alias Wardrik.EventLog.Timeline

  @type t() :: Timeline.t()

  @doc "Returns a timeline before any event."
  @spec new() :: t()
  def new, do: Timeline.init([])

  @doc "Folds `events`, oldest first, into a new timeline."
  @spec fold(Enumerable.t()) :: t()
  def fold(events), do: Enum.reduce(events, new(), &__MODULE__.apply(&2, &1))

  @doc "Folds one more event into `timeline`."
  @spec apply(t(), Wardrik.Event.t() | map()) :: t()
  def apply(timeline, event), do: Timeline.handle_event(Wardrik.Views.json(event), timeline)

  @doc "Returns the items, oldest first."
  @spec items(t()) :: [map()]
  defdelegate items(timeline), to: Timeline

  @doc "Returns the item `id`, or `nil`."
  @spec item(t(), String.t()) :: map() | nil
  defdelegate item(timeline, id), to: Timeline

  @doc """
  Returns the ids of the items the last event changed, or `:reset` where it cleared the
  conversation and every item before it is gone.
  """
  @spec touched(t()) :: [String.t()] | :reset
  defdelegate touched(timeline), to: Timeline

  @doc "Returns the latest run, or `nil` before any."
  @spec current_run(t()) :: map() | nil
  defdelegate current_run(timeline), to: Timeline

  @doc "Returns whether the latest run is going on."
  @spec running?(t()) :: boolean()
  defdelegate running?(timeline), to: Timeline

  @doc "Returns the calls the runs wait on a person for, oldest first."
  @spec interrupts(t()) :: [map()]
  defdelegate interrupts(timeline), to: Timeline
end
