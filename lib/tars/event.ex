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

  @doc "Whether the event came from a turn itself rather than work the turn spawned."
  @spec root?(t()) :: boolean()
  def root?(%__MODULE__{source: %Source{trace: trace}}), do: Trace.root?(trace)
end
