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

  @typedoc "An event payload. Its first element names the event."
  @type payload() :: tuple()

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
