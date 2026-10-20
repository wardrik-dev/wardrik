defmodule Wardrik.Bus.Event do
  @moduledoc """
  One thing that happened, and where it happened.

  The payload is a struct of its own for each kind of event, with named
  fields, so a subscriber matches the fields it reads and a field added later
  touches no one who does not read it; this struct is the envelope around it.

      def handle_info(%Wardrik.Bus.Event{payload: %Wardrik.Bus.ToolFinished{name: name}}, state)

  `root?/1` separates the turn's own events from work it spawned, which is
  what lets one subscription render a whole tree.
  """

  alias Wardrik.Bus
  alias Wardrik.Bus.Source
  alias Wardrik.Trace

  @enforce_keys [:source, :payload, :at]
  defstruct [:id, :source, :payload, :at]

  @typedoc """
  An event payload: one of the structs below, each named for its kind, as
  `type/1` names it.

  Every payload core emits is listed here. A package emits these and no
  others; `Wardrik.Tool.Context.progress/3` is how a tool reports progress.

    * Agent lifecycle, on the turn's root span: `Wardrik.Bus.TurnStarted`,
      `Wardrik.Bus.TurnFinished`, `Wardrik.Bus.TurnFailed`,
      `Wardrik.Bus.TurnInterrupted`, `Wardrik.Bus.TurnParked`,
      `Wardrik.Bus.TurnResumed`, `Wardrik.Bus.CallDecided`,
      `Wardrik.Bus.ContextCompacted`.
    * Agent lifecycle, each on the root of a trace of its own:
      `Wardrik.Bus.MessageQueued`, `Wardrik.Bus.AgentStarted`,
      `Wardrik.Bus.AgentStopped`, `Wardrik.Bus.ContextCleared`,
      `Wardrik.Bus.TriggerFired`.
    * What the agent is doing, on the span of the event that changed it:
      `Wardrik.Bus.ActivityChanged`.
    * Spans other than a tool call's, and delegations, on their own span:
      `Wardrik.Bus.SpanStarted`, `Wardrik.Bus.SpanFinished`,
      `Wardrik.Bus.DelegationStarted`, `Wardrik.Bus.DelegationFinished`.
    * Model calls: `Wardrik.Bus.ModelStarted`,
      `Wardrik.Bus.ModelFinished`, `Wardrik.Bus.ModelRetrying`,
      `Wardrik.Bus.Result`, `Wardrik.Bus.Thinking`,
      `Wardrik.Bus.ToolCall`, `Wardrik.Bus.DeadlineReached`.
    * Tool calls, on the call's span: `Wardrik.Bus.ToolStarted`,
      `Wardrik.Bus.ToolFinished`, `Wardrik.Bus.ToolReplayed`,
      `Wardrik.Bus.ToolDenied`, `Wardrik.Bus.ToolParked`,
      `Wardrik.Bus.ToolProgress`. The first of them opens the span, and
      the one that settles the call closes it; see `ended/1`.
  """
  @type payload() ::
          Wardrik.Bus.TurnStarted.t()
          | Wardrik.Bus.TurnFinished.t()
          | Wardrik.Bus.TurnFailed.t()
          | Wardrik.Bus.TurnInterrupted.t()
          | Wardrik.Bus.TurnParked.t()
          | Wardrik.Bus.TurnResumed.t()
          | Wardrik.Bus.CallDecided.t()
          | Wardrik.Bus.MessageQueued.t()
          | Wardrik.Bus.AgentStarted.t()
          | Wardrik.Bus.AgentStopped.t()
          | Wardrik.Bus.ContextCompacted.t()
          | Wardrik.Bus.ContextCleared.t()
          | Wardrik.Bus.TriggerFired.t()
          | Wardrik.Bus.ActivityChanged.t()
          | Wardrik.Bus.SpanStarted.t()
          | Wardrik.Bus.SpanFinished.t()
          | Wardrik.Bus.DelegationStarted.t()
          | Wardrik.Bus.DelegationFinished.t()
          | Wardrik.Bus.ModelStarted.t()
          | Wardrik.Bus.ModelFinished.t()
          | Wardrik.Bus.ModelRetrying.t()
          | Wardrik.Bus.Result.t()
          | Wardrik.Bus.Thinking.t()
          | Wardrik.Bus.ToolCall.t()
          | Wardrik.Bus.DeadlineReached.t()
          | Wardrik.Bus.ToolStarted.t()
          | Wardrik.Bus.ToolFinished.t()
          | Wardrik.Bus.ToolReplayed.t()
          | Wardrik.Bus.ToolDenied.t()
          | Wardrik.Bus.ToolParked.t()
          | Wardrik.Bus.ToolProgress.t()

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
  @spec announce(Wardrik.AgentAddress.t(), payload()) :: :ok
  def announce(agent, payload), do: emit(Source.root(agent), payload)

  @types %{
    Wardrik.Bus.TurnStarted => :turn_started,
    Wardrik.Bus.TurnFinished => :turn_finished,
    Wardrik.Bus.TurnFailed => :turn_failed,
    Wardrik.Bus.TurnInterrupted => :turn_interrupted,
    Wardrik.Bus.TurnParked => :turn_parked,
    Wardrik.Bus.TurnResumed => :turn_resumed,
    Wardrik.Bus.CallDecided => :call_decided,
    Wardrik.Bus.MessageQueued => :message_queued,
    Wardrik.Bus.AgentStarted => :agent_started,
    Wardrik.Bus.AgentStopped => :agent_stopped,
    Wardrik.Bus.ContextCompacted => :context_compacted,
    Wardrik.Bus.ContextCleared => :context_cleared,
    Wardrik.Bus.TriggerFired => :trigger_fired,
    Wardrik.Bus.ActivityChanged => :activity_changed,
    Wardrik.Bus.SpanStarted => :span_started,
    Wardrik.Bus.SpanFinished => :span_finished,
    Wardrik.Bus.DelegationStarted => :delegation_started,
    Wardrik.Bus.DelegationFinished => :delegation_finished,
    Wardrik.Bus.ModelStarted => :model_started,
    Wardrik.Bus.ModelFinished => :model_finished,
    Wardrik.Bus.ModelRetrying => :model_retrying,
    Wardrik.Bus.Result => :result,
    Wardrik.Bus.Thinking => :thinking,
    Wardrik.Bus.ToolCall => :tool_call,
    Wardrik.Bus.DeadlineReached => :deadline_reached,
    Wardrik.Bus.ToolStarted => :tool_started,
    Wardrik.Bus.ToolFinished => :tool_finished,
    Wardrik.Bus.ToolReplayed => :tool_replayed,
    Wardrik.Bus.ToolDenied => :tool_denied,
    Wardrik.Bus.ToolParked => :tool_parked,
    Wardrik.Bus.ToolProgress => :tool_progress
  }

  @doc "The name of the event, as an atom: `:tool_finished` for a `Wardrik.Bus.ToolFinished`."
  @spec type(t()) :: atom()
  def type(%__MODULE__{payload: %kind{}}), do: Map.fetch!(@types, kind)

  @typedoc """
  How much of an agent's stream to take.

    * `:lifecycle` - the shape of the work: turns starting and ending, spans
      opening and closing, a tool call's events among them, and delegations
      starting and ending, with what the agent is doing now as
      `Wardrik.Bus.ActivityChanged`
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
  def ended(%Wardrik.Bus.ToolFinished{result: result}), do: answered(result)
  def ended(%Wardrik.Bus.ToolReplayed{result: result}), do: answered(result)
  def ended(%Wardrik.Bus.ToolDenied{reason: reason}), do: {:error, reason}
  def ended(%Wardrik.Bus.ToolParked{}), do: {:error, :parked}
  def ended(_payload), do: nil

  defp answered({:error, reason}), do: {:error, reason}

  defp answered({:ok, %{"error" => error}} = result),
    do: if(Wardrik.Tool.Result.ok?(result), do: :ok, else: {:error, error})

  defp answered(_result), do: :ok

  @doc "Whether the event came from a turn itself rather than work the turn spawned."
  @spec root?(t()) :: boolean()
  def root?(%__MODULE__{source: %Source{trace: trace}}), do: Trace.root?(trace)
end
