defmodule Wardrik.Event do
  @moduledoc """
  One thing that happened, and where it happened.

  The payload is a struct of its own for each kind of event, with named
  fields, so a subscriber matches the fields it reads and a field added later
  touches no one who does not read it; this struct is the envelope around it.

      def handle_info(%Wardrik.Event{payload: %Wardrik.Event.ToolFinished{name: name}}, state)

  `root?/1` separates the turn's own events from work it spawned, which is
  what lets one subscription render a whole tree.
  """

  alias Wardrik.Event.Bus
  alias Wardrik.Event.Source
  alias Wardrik.Trace

  @enforce_keys [:source, :payload, :at]
  defstruct [:id, :source, :payload, :at]

  @typedoc """
  An event payload: one of the structs below, each named for its kind, as
  `type/1` names it.

  Every payload core emits is listed here. A package emits these and no
  others; `Wardrik.Tool.Context.progress/3` is how a tool reports progress.

    * Agent lifecycle, on the turn's root span: `Wardrik.Event.TurnStarted`,
      `Wardrik.Event.TurnFinished`, `Wardrik.Event.TurnFailed`,
      `Wardrik.Event.TurnInterrupted`, `Wardrik.Event.TurnParked`,
      `Wardrik.Event.TurnResumed`, `Wardrik.Event.CallDecided`,
      `Wardrik.Event.ContextCompacted`.
    * Agent lifecycle, each on the root of a trace of its own:
      `Wardrik.Event.MessageQueued`, `Wardrik.Event.AgentStarted`,
      `Wardrik.Event.AgentStopped`, `Wardrik.Event.ContextCleared`,
      `Wardrik.Event.TriggerFired`.
    * What the agent is doing, on the span of the event that changed it:
      `Wardrik.Event.ActivityChanged`.
    * Spans other than a tool call's, and delegations, on their own span:
      `Wardrik.Event.SpanStarted`, `Wardrik.Event.SpanFinished`,
      `Wardrik.Event.DelegationStarted`, `Wardrik.Event.DelegationFinished`.
    * Model calls: `Wardrik.Event.ModelStarted`,
      `Wardrik.Event.ModelFinished`, `Wardrik.Event.ModelRetrying`,
      `Wardrik.Event.Result`, `Wardrik.Event.Thinking`,
      `Wardrik.Event.ToolCall`, `Wardrik.Event.DeadlineReached`.
    * Tool calls, on the call's span: `Wardrik.Event.ToolStarted`,
      `Wardrik.Event.ToolFinished`, `Wardrik.Event.ToolReplayed`,
      `Wardrik.Event.ToolDenied`, `Wardrik.Event.ToolParked`,
      `Wardrik.Event.ToolProgress`. The first of them opens the span, and
      the one that settles the call closes it; see `ended/1`.
  """
  @type payload() ::
          __MODULE__.TurnStarted.t()
          | __MODULE__.TurnFinished.t()
          | __MODULE__.TurnFailed.t()
          | __MODULE__.TurnInterrupted.t()
          | __MODULE__.TurnParked.t()
          | __MODULE__.TurnResumed.t()
          | __MODULE__.CallDecided.t()
          | __MODULE__.MessageQueued.t()
          | __MODULE__.AgentStarted.t()
          | __MODULE__.AgentStopped.t()
          | __MODULE__.ContextCompacted.t()
          | __MODULE__.ContextCleared.t()
          | __MODULE__.TriggerFired.t()
          | __MODULE__.ActivityChanged.t()
          | __MODULE__.SpanStarted.t()
          | __MODULE__.SpanFinished.t()
          | __MODULE__.DelegationStarted.t()
          | __MODULE__.DelegationFinished.t()
          | __MODULE__.ModelStarted.t()
          | __MODULE__.ModelFinished.t()
          | __MODULE__.ModelRetrying.t()
          | __MODULE__.Result.t()
          | __MODULE__.Thinking.t()
          | __MODULE__.ToolCall.t()
          | __MODULE__.DeadlineReached.t()
          | __MODULE__.ToolStarted.t()
          | __MODULE__.ToolFinished.t()
          | __MODULE__.ToolReplayed.t()
          | __MODULE__.ToolDenied.t()
          | __MODULE__.ToolParked.t()
          | __MODULE__.ToolProgress.t()

  @typedoc """
  A payload, who emitted it, and when, under an id of its own: a UUIDv7 that
  every copy of the event carries, and that `Wardrik.Event.Codec` sends as the
  CloudEvent's `id`.
  """
  @type t() :: %__MODULE__{
          id: String.t() | nil,
          source: Source.t(),
          payload: payload(),
          at: integer()
        }

  @doc "Build an event without publishing it."
  @spec new(Source.t(), payload()) :: t()
  def new(%Source{} = source, %_kind{} = payload) do
    %__MODULE__{
      id: Wardrik.UUID.v7(),
      source: source,
      payload: payload,
      at: System.system_time(:microsecond)
    }
  end

  @doc "Build an event and publish it to everyone watching the source's topic."
  @spec emit(Source.t(), payload()) :: :ok
  def emit(%Source{} = source, payload) do
    source |> new(payload) |> Bus.publish()
  end

  @doc "Publishes `payload` on the agent `agent`'s topic, at the root of a trace of its own."
  @spec announce(Wardrik.AgentID.t(), payload()) :: :ok
  def announce(%Wardrik.AgentID{} = agent, payload), do: emit(Source.root(agent), payload)

  @types %{
    __MODULE__.TurnStarted => :turn_started,
    __MODULE__.TurnFinished => :turn_finished,
    __MODULE__.TurnFailed => :turn_failed,
    __MODULE__.TurnInterrupted => :turn_interrupted,
    __MODULE__.TurnParked => :turn_parked,
    __MODULE__.TurnResumed => :turn_resumed,
    __MODULE__.CallDecided => :call_decided,
    __MODULE__.MessageQueued => :message_queued,
    __MODULE__.AgentStarted => :agent_started,
    __MODULE__.AgentStopped => :agent_stopped,
    __MODULE__.ContextCompacted => :context_compacted,
    __MODULE__.ContextCleared => :context_cleared,
    __MODULE__.TriggerFired => :trigger_fired,
    __MODULE__.ActivityChanged => :activity_changed,
    __MODULE__.SpanStarted => :span_started,
    __MODULE__.SpanFinished => :span_finished,
    __MODULE__.DelegationStarted => :delegation_started,
    __MODULE__.DelegationFinished => :delegation_finished,
    __MODULE__.ModelStarted => :model_started,
    __MODULE__.ModelFinished => :model_finished,
    __MODULE__.ModelRetrying => :model_retrying,
    __MODULE__.Result => :result,
    __MODULE__.Thinking => :thinking,
    __MODULE__.ToolCall => :tool_call,
    __MODULE__.DeadlineReached => :deadline_reached,
    __MODULE__.ToolStarted => :tool_started,
    __MODULE__.ToolFinished => :tool_finished,
    __MODULE__.ToolReplayed => :tool_replayed,
    __MODULE__.ToolDenied => :tool_denied,
    __MODULE__.ToolParked => :tool_parked,
    __MODULE__.ToolProgress => :tool_progress
  }

  @doc "The name of the event, as an atom: `:tool_finished` for a `Wardrik.Event.ToolFinished`."
  @spec type(t()) :: atom()
  def type(%__MODULE__{payload: %kind{}}), do: Map.fetch!(@types, kind)

  @typedoc """
  How much of an agent's stream to take.

    * `:lifecycle` - the shape of the work: turns starting and ending, spans
      opening and closing, a tool call's events among them, and delegations
      starting and ending, with what the agent is doing now as
      `Wardrik.Event.ActivityChanged`
    * `:activity` - what the agent is doing inside that shape: model requests,
      a tool call's progress, answer text and reasoning
    * `:raw` - everything, including each tool call as the model streams it
  """
  @type level() :: :lifecycle | :activity | :raw

  @levels [:lifecycle, :activity, :raw]

  @lifecycle [
    :turn_started,
    :turn_finished,
    :turn_failed,
    :turn_interrupted,
    :turn_parked,
    :turn_resumed,
    :call_decided,
    :message_queued,
    :agent_started,
    :agent_stopped,
    :trigger_fired,
    :activity_changed,
    :span_started,
    :span_finished,
    :tool_started,
    :tool_finished,
    :tool_replayed,
    :tool_denied,
    :tool_parked,
    :delegation_started,
    :delegation_finished
  ]

  @raw [:tool_call]

  @doc "Every level, from least to most."
  @spec levels() :: [level()]
  def levels, do: @levels

  @doc """
  The lowest level at which `type` is delivered.

  `:tool_call` repeats what `:tool_started` reports with the call resolved.
  A type nobody has classified is activity.
  """
  @spec level(atom()) :: level()
  def level(type) when type in @lifecycle, do: :lifecycle
  def level(type) when type in @raw, do: :raw
  def level(_type), do: :activity

  @doc "Whether a subscriber at `level` is sent events of `type`."
  @spec delivers?(level(), atom()) :: boolean()
  def delivers?(level, type) when level in @levels do
    rank(level) >= rank(level(type))
  end

  defp rank(level), do: Enum.find_index(@levels, &(&1 == level))

  @doc """
  How the tool call whose span `payload` closes ended, or `nil` for a payload
  that closes no tool call's span: answered, answered from the ledger,
  refused, or parked on a person, as `{:error, :parked}`. A tool that reports
  its own failure (see `Wardrik.Tool.Result`) answers the model, and ends as
  an error, so a surface can say the call did not do its job.
  """
  @spec ended(payload()) :: Wardrik.Run.outcome() | nil
  def ended(%__MODULE__.ToolFinished{result: result}), do: answered(result)
  def ended(%__MODULE__.ToolReplayed{result: result}), do: answered(result)
  def ended(%__MODULE__.ToolDenied{reason: reason}), do: {:error, reason}
  def ended(%__MODULE__.ToolParked{}), do: {:error, :parked}
  def ended(_payload), do: nil

  defp answered({:error, reason}), do: {:error, reason}

  defp answered({:ok, %{"error" => error}} = result),
    do: if(Wardrik.Tool.Result.ok?(result), do: :ok, else: {:error, error})

  defp answered(_result), do: :ok

  @doc "Whether the event came from a turn itself rather than work the turn spawned."
  @spec root?(t()) :: boolean()
  def root?(%__MODULE__{source: %Source{trace: trace}}), do: Trace.root?(trace)
end
