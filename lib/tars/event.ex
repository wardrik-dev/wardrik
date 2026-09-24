defmodule Tars.Event do
  @moduledoc """
  One thing that happened, and where it happened.

  The payload stays a tuple, so subscribers match on it the way they always
  have; this struct is the envelope around it.

      def handle_info(%Tars.Event{payload: {:tool_finished, id, name, result}}, state)

  `root?/1` separates the turn's own events from work it spawned, which is
  what lets one subscription render a whole tree.
  """

  alias Tars.Event.Bus
  alias Tars.Event.Source
  alias Tars.Trace

  @enforce_keys [:source, :payload, :at]
  defstruct [:source, :payload, :at]

  @typedoc """
  An event payload. Its first element names the event.

  Every payload core emits is listed here. A package emits these and no
  others; `Tars.Tool.progress/2` is how a tool reports `:tool_progress`.

  Agent lifecycle, on the turn's root span:

    * `{:turn_started, questions}`, `{:turn_finished, messages}`,
      `{:turn_failed, reason}`, `{:turn_interrupted, stats}`,
      `{:turn_parked, calls}`, `{:turn_resumed, decisions}`,
      `{:call_decided, call_id, decision, by}`, one per call a person
      answered, with the `Tars.Principal` who did, or `nil` where no caller
      said, `{:context_compacted, stats}`, `{:schedule_fired, name, outcome}`

  Spans and delegations, on their own span:

    * `{:span_started, name}`, `{:span_finished, outcome, duration_ms}`
    * `{:delegation_started, prompt}`, `{:delegation_finished, outcome, duration_ms}`

  Model calls:

    * `{:model_started, model_spec}`, `{:model_finished, outcome, duration_ms}`
    * `{:result, text}`, `{:thinking, text}`, `{:meta, chunk}`, `{:chunk, chunk}`,
      `{:tool_call, call}`, `{:deadline_reached, message_count}`

  Tool calls, on the call's span:

    * `{:tool_started, call_id, name}`, `{:tool_finished, call_id, name, result}`
    * `{:tool_denied, call_id, name, reason}`, `{:tool_parked, call_id, name, prompt}`
    * `{:tool_progress, call_id, name, progress, total}`
    * `{:tool_replayed, call_id, name, result}`, a call answered from the
      ledger without running again
  """
  @type payload() ::
          {:turn_started, [String.t()]}
          | {:turn_finished, [ReqLLM.Message.t()]}
          | {:turn_failed, term()}
          | {:turn_interrupted, Tars.Agent.State.stats()}
          | {:turn_parked, [{Tars.Tool.call(), String.t()}]}
          | {:turn_resumed, %{String.t() => term()}}
          | {:call_decided, String.t(), Tars.LLM.Turn.Parked.decision(), Tars.Principal.t() | nil}
          | {:context_compacted, Tars.Compaction.stats()}
          | {:schedule_fired, String.t(), Tars.Schedule.outcome()}
          | {:span_started, String.t()}
          | {:span_finished, Tars.Scope.outcome(), non_neg_integer()}
          | {:delegation_started, String.t()}
          | {:delegation_finished, {:ok, String.t()} | {:error, term()}, non_neg_integer()}
          | {:model_started, term()}
          | {:model_finished, :ok | {:error, term()}, non_neg_integer()}
          | {:result, String.t()}
          | {:thinking, String.t()}
          | {:meta, term()}
          | {:chunk, term()}
          | {:tool_call, term()}
          | {:deadline_reached, non_neg_integer()}
          | {:tool_started, String.t(), String.t()}
          | {:tool_finished, String.t(), String.t(), term()}
          | {:tool_replayed, String.t(), String.t(), term()}
          | {:tool_denied, String.t(), String.t(), String.t()}
          | {:tool_parked, String.t(), String.t(), String.t()}
          | {:tool_progress, String.t(), String.t(), number(), number() | nil}

  @typedoc "A payload, who emitted it, and when."
  @type t() :: %__MODULE__{source: Source.t(), payload: payload(), at: integer()}

  @doc "Build an event without publishing it."
  @spec new(Source.t(), payload()) :: t()
  def new(%Source{} = source, payload) when is_tuple(payload) do
    %__MODULE__{source: source, payload: payload, at: System.system_time(:microsecond)}
  end

  @doc "Build an event and publish it to everyone watching the source's topic."
  @spec emit(Source.t(), payload()) :: :ok
  def emit(%Source{} = source, payload) do
    source |> new(payload) |> Bus.publish()
  end

  @doc "The name of the event, taken from the first element of its payload."
  @spec type(t()) :: atom()
  def type(%__MODULE__{payload: payload}), do: elem(payload, 0)

  @typedoc """
  How much of an agent's stream to take.

    * `:lifecycle` - the shape of the work: turns starting and ending, spans
      opening and closing, and delegations starting and ending
    * `:activity` - what the agent is doing inside that shape: model requests,
      tool calls, answer text and reasoning
    * `:raw` - everything, including the provider's own stream records
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
    :schedule_fired,
    :span_started,
    :span_finished,
    :delegation_started,
    :delegation_finished
  ]

  @raw [:chunk, :tool_call]

  @doc "Every level, from least to most."
  @spec levels() :: [level()]
  def levels, do: @levels

  @doc """
  The lowest level at which `type` is delivered.

  `:chunk` repeats every stream record that `:result`, `:thinking` and
  `:tool_call` already report, and `:tool_call` repeats what `:tool_started`
  reports with the call resolved. A type nobody has classified is activity.
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

  @doc "Whether the event came from a turn itself rather than work the turn spawned."
  @spec root?(t()) :: boolean()
  def root?(%__MODULE__{source: %Source{trace: trace}}), do: Trace.root?(trace)
end
