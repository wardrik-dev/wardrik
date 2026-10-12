defmodule Wardrik.Event.Log.Writer do
  @moduledoc """
  An agent's end of its `Wardrik.Event.Log`: how far the log has got, and which
  message each model call is streaming.

  `Wardrik.Agent` holds one and hands it every event of its own, in the order they
  reach it:

      writer = Writer.open(Writer.new(key, last_written), agent_started)
      {:ok, writer} = Writer.append(writer, event)

  ## Numbering

  A durable event is written at the next sequence number, with a write
  conditional on nothing being there yet, then delivered to subscribers. A live
  one is delivered alone. A text or reasoning delta names the message its model
  call announced on the same span, and one with no message open is not sent.

  ## Owners

  `open/2` writes the log down among `Wardrik.Event.Log.logs/0`, and finds
  the head. From the sequence the agent last wrote down, it
  reads forward through consensus to the first number nobody has written, and
  writes `agent.started` there. A conflict while it does is an owner before it
  still writing, so it moves to the new end and tries again.

  From then on a conflict is an owner after it. The writer stops, and answers
  `{:error, :fenced, writer}` to everything after. The one exception is a
  write it could not confirm, which it recognises there as its own.

  A write the store fails for any other reason is logged and not retried: that
  event is not written, and the next one takes its number.

  ## Ahead of the bus

  `append_ahead/2` writes an event the agent has yet to publish, so it is in
  the log before the agent acts on it. Its copy arriving from the bus is passed
  over.
  """

  require Logger

  alias Wardrik.Event
  alias Wardrik.Event.Bus
  alias Wardrik.Event.Codec
  alias Wardrik.Event.Log
  alias Wardrik.Event.Log.Entry

  @deltas [:result, :thinking]

  # Writes the store could not confirm, remembered so one found committed is
  # taken as this writer's own.
  @unconfirmed 8

  @enforce_keys [:agent_id]
  defstruct [:agent_id, head: 0, fenced: false, messages: %{}, ahead: [], unconfirmed: []]

  @typedoc """
  The agent, the last sequence written, whether another owner has taken over,
  the message open on each span, and the ids of events written ahead of the
  bus and of writes not confirmed.
  """
  @type t() :: %__MODULE__{
          agent_id: Bus.agent_id(),
          head: non_neg_integer(),
          fenced: boolean(),
          messages: %{String.t() => String.t()},
          ahead: [String.t()],
          unconfirmed: [String.t()]
        }

  @typedoc "What an append answers."
  @type result() :: {:ok, t()} | {:error, :fenced | term(), t()}

  @doc "A writer for `agent_id`, whose log is known to reach `head`. Not yet open."
  @spec new(Bus.agent_id(), non_neg_integer()) :: t()
  def new(%Wardrik.AgentID{} = agent_id, head \\ 0) when is_integer(head) and head >= 0,
    do: %__MODULE__{agent_id: agent_id, head: head}

  @doc """
  Finds the head of the log and writes `started`, the agent's
  `{:agent_started, ...}` event, after it, ahead of the bus.
  """
  @spec open(t(), Event.t()) :: t()
  def open(%__MODULE__{} = writer, %Event{payload: {:agent_started, _, _, _}} = started) do
    with {:error, reason} <- Log.opened(writer.agent_id),
         do: Logger.warning("Could not list #{writer.agent_id}'s log: #{inspect(reason)}")

    known = max(writer.head, Log.oldest(writer.agent_id, consistent: true) - 1)
    start(%{writer | head: Log.head(writer.agent_id, known)}, started)
  end

  defp start(writer, started) do
    case put(writer, started) do
      {:ok, writer} ->
        ahead(writer, started)

      {:conflict, writer} ->
        start(%{writer | head: Log.head(writer.agent_id, writer.head + 1)}, started)

      {:error, _reason, writer} ->
        writer
    end
  end

  @doc """
  Numbers `event` and passes it on: written and delivered when it is durable,
  delivered when it is live, and dropped when `Wardrik.Event.Codec` does not send
  it. An event written ahead of the bus is passed over.
  """
  @spec append(t(), Event.t()) :: result()
  def append(%__MODULE__{} = writer, %Event{id: id} = event) do
    if id in writer.ahead,
      do: {:ok, %{writer | ahead: List.delete(writer.ahead, id)}},
      else: write(writer, event)
  end

  @doc "Appends an event the agent has yet to publish. Its copy from the bus is passed over."
  @spec append_ahead(t(), Event.t()) :: result()
  def append_ahead(%__MODULE__{} = writer, %Event{} = event) do
    with {:ok, writer} <- write(writer, event), do: {:ok, ahead(writer, event)}
  end

  defp ahead(writer, event), do: %{writer | ahead: [event.id | writer.ahead]}

  defp write(%__MODULE__{fenced: true} = writer, _event), do: {:error, :fenced, writer}

  defp write(writer, event) do
    writer = follow(writer, event)

    if Codec.durable?(Event.type(event)), do: durable(writer, event), else: live(writer, event)
  end

  defp follow(writer, %Event{payload: {:model_started, message_id, _spec, _decided_by}} = event),
    do: %{writer | messages: Map.put(writer.messages, span(event), message_id)}

  defp follow(
         writer,
         %Event{payload: {:model_finished, _id, _outcome, _ms, _response, _cost}} = event
       ),
       do: %{writer | messages: Map.delete(writer.messages, span(event))}

  defp follow(writer, _event), do: writer

  defp span(event), do: event.source.trace.span_id

  # -- durable ---------------------------------------------------------------

  defp durable(writer, event) do
    case put(writer, event) do
      {:conflict, writer} -> taken(writer, event)
      result -> result
    end
  end

  defp put(writer, event) do
    sequence = writer.head + 1
    {:ok, cloud_event} = Codec.encode(event, sequence: sequence)
    key = Log.key(writer.agent_id, sequence)

    case WardrikStore.put(Log.namespace(), key, cloud_event, if_vsn: nil) do
      {:ok, _vsn} ->
        entry = %Entry{event: cloud_event, sequence: sequence, follows: writer.head}
        :ok = Log.publish(writer.agent_id, entry)
        {:ok, %{writer | head: sequence, unconfirmed: []}}

      {:error, :conflict} ->
        {:conflict, writer}

      {:error, reason} ->
        Logger.warning("Could not write #{key} to the event log: #{inspect(reason)}")
        unconfirmed = Enum.take([event.id | writer.unconfirmed], @unconfirmed)
        {:error, reason, %{writer | unconfirmed: unconfirmed}}
    end
  end

  # Something was written at this number first: this writer, on a write it
  # could not confirm, or an owner that has taken over.
  defp taken(writer, event) do
    sequence = writer.head + 1

    written =
      WardrikStore.get(Log.namespace(), Log.key(writer.agent_id, sequence), consistent: true)

    if is_map(written) and written["id"] in writer.unconfirmed do
      durable(%{writer | head: sequence, unconfirmed: []}, event)
    else
      Logger.warning("#{writer.agent_id} has another owner, so this one stops writing its log")
      {:error, :fenced, %{writer | fenced: true}}
    end
  end

  # -- live ------------------------------------------------------------------

  defp live(writer, %Event{payload: {type, _text}} = event) when type in @deltas do
    case Map.fetch(writer.messages, span(event)) do
      {:ok, message_id} -> deliver(writer, event, message_id: message_id)
      :error -> {:ok, writer}
    end
  end

  defp live(writer, event), do: deliver(writer, event, [])

  defp deliver(writer, event, opts) do
    with {:ok, cloud_event} <- Codec.encode(event, opts) do
      Log.publish(writer.agent_id, %Entry{event: cloud_event, follows: writer.head})
    end

    {:ok, writer}
  end
end
