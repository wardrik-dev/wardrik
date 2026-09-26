defmodule Wardrik.Event.Log do
  @moduledoc """
  Each agent's events as CloudEvents, numbered and kept, so a client can
  resume from the last one it saw, on any node and across a `kill -9`.

      {:ok, events} = Wardrik.Event.Log.read("acme/ops/triage", starting_after: 40)

  ## Written by the agent alone

  `Wardrik.Agent` is one process per key across the cluster, and it is its log's
  only writer, through a `Wardrik.Event.Log.Writer`. It follows its own events,
  encodes each with `Wardrik.Event.Codec`, and writes the durable ones to
  `Wardrik.Store` under the next sequence number, in the order they reach it. A
  write is conditional on nothing being written under that number yet, so two
  owners of one agent can never both write it.

  Sequence numbers start at 1, run without a gap, and are never reused under
  one agent, even one forgotten and started again under the same key.

  ## Following it live

  `subscribe/1` delivers every event the writer numbers, durable and live, as
  a `Wardrik.Event.Log.Entry`, in the order it numbered them, to a subscriber on
  any node. Live events, the text and reasoning deltas and tool progress, are
  delivered and never written.

  A client that resumes subscribes first, then reads from the last sequence it
  saw, then takes the entries that follow what it read; see
  `Wardrik.Event.Log.Entry.follows?/2`.

  ## Reading it

  `read/2` answers the events after a sequence number, oldest first. A read
  from before what the log still holds answers `{:gap, oldest}`, and the client
  starts again from the agent's snapshot, which carries the head sequence.

  ## Retention

  Events are kept 30 days. After each run the agent drops those older than
  that, never past the last event it wrote, so an open run keeps every event
  it has.
  """

  alias Wardrik.Event.Bus
  alias Wardrik.Event.Log.Entry
  alias Wardrik.Store

  @ns :events

  @retention_days 30

  @default_limit 500

  @padding 12

  @doc false
  def child_spec(_opts), do: Group.child_spec(name: __MODULE__)

  @doc "How long events are kept, in days."
  @spec retention_days() :: pos_integer()
  def retention_days, do: @retention_days

  @doc """
  The events of `agent_id` after a sequence number, oldest first.

  Options:

    * `:starting_after` - the last sequence already seen, `0` for all
    * `:limit` - how many to answer at most, #{@default_limit} by default

  Answers `{:gap, oldest}` when events after `:starting_after` have been
  dropped, where `oldest` is the first one still held.
  """
  @spec read(Bus.agent_id(), keyword()) :: {:ok, [map()]} | {:gap, pos_integer()}
  def read(agent_id, opts \\ []) when is_binary(agent_id) do
    next = Keyword.get(opts, :starting_after, 0) + 1
    oldest = oldest(agent_id)

    if next < oldest,
      do: {:gap, oldest},
      else: {:ok, take(agent_id, next, Keyword.get(opts, :limit, @default_limit))}
  end

  # Reads by number stop at the first one missing here. It is read again
  # through consensus before it is taken as the end, since this node's copy of
  # the store may be behind the node that wrote it.
  defp take(agent_id, sequence, limit) do
    Stream.unfold({sequence, limit}, fn
      {_sequence, 0} ->
        nil

      {sequence, limit} ->
        key = key(agent_id, sequence)

        case Store.get(@ns, key) || Store.get(@ns, key, consistent: true) do
          nil -> nil
          event -> {event, {sequence + 1, limit - 1}}
        end
    end)
    |> Enum.to_list()
  end

  @doc """
  Subscribes the calling process to the entries `agent_id`'s writer numbers,
  as `Wardrik.Event.Log.Entry` messages.
  """
  @spec subscribe(Bus.agent_id()) :: :ok
  def subscribe(agent_id) when is_binary(agent_id), do: Group.join(__MODULE__, agent_id, %{})

  @spec unsubscribe(Bus.agent_id()) :: :ok
  def unsubscribe(agent_id) when is_binary(agent_id), do: Group.leave(__MODULE__, agent_id)

  @doc "Delivers an entry to every subscriber to its agent. A writer's to call."
  @spec publish(Bus.agent_id(), Entry.t()) :: :ok
  def publish(agent_id, %Entry{} = entry), do: Group.dispatch(__MODULE__, agent_id, entry)

  @doc """
  Drops the events of `agent_id` written before `cutoff`, oldest first, and
  none after the sequence `through`.
  """
  @spec trim(Bus.agent_id(), non_neg_integer(), DateTime.t()) :: :ok | {:error, term()}
  def trim(agent_id, through, %DateTime{} = cutoff) do
    {dropped, vsn} = lookup_dropped(agent_id)

    case expired_through(agent_id, dropped, through, cutoff) do
      ^dropped -> :ok
      last -> with :ok <- put_dropped(agent_id, last, vsn), do: drop(agent_id, dropped + 1, last)
    end
  end

  defp expired_through(agent_id, sequence, through, cutoff) do
    next = sequence + 1

    with true <- next <= through,
         %{"time" => time} <- Store.get(@ns, key(agent_id, next)),
         {:ok, at, _offset} <- DateTime.from_iso8601(time),
         :lt <- DateTime.compare(at, cutoff) do
      expired_through(agent_id, next, through, cutoff)
    else
      _kept -> sequence
    end
  end

  # What has been dropped is written down before the events go, so a read never
  # finds them missing without being told of the gap.
  defp put_dropped(agent_id, last, vsn) do
    case Store.put(@ns, dropped_key(agent_id), last, if_vsn: vsn) do
      {:ok, _vsn} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp drop(agent_id, first, last) do
    Enum.reduce_while(first..last//1, :ok, fn sequence, :ok ->
      key = key(agent_id, sequence)

      case Store.lookup(@ns, key) do
        {_event, vsn} -> Store.delete(@ns, key, if_vsn: vsn) |> continue()
        nil -> {:cont, :ok}
      end
    end)
  end

  defp continue(:ok), do: {:cont, :ok}
  defp continue({:error, reason}), do: {:halt, {:error, reason}}

  @doc """
  The first sequence of `agent_id` the log still holds, or would hold: `1`
  until events have been dropped. `consistent: true` reads it through
  consensus.
  """
  @spec oldest(Bus.agent_id(), keyword()) :: pos_integer()
  def oldest(agent_id, opts \\ []), do: (Store.get(@ns, dropped_key(agent_id), opts) || 0) + 1

  defp lookup_dropped(agent_id) do
    case Store.lookup(@ns, dropped_key(agent_id)) do
      {dropped, vsn} -> {dropped, vsn}
      nil -> {0, nil}
    end
  end

  @doc "The store key the event of `agent_id` at `sequence` is written under."
  @spec key(Bus.agent_id(), pos_integer()) :: Store.key()
  def key(agent_id, sequence),
    do: agent_id <> "/" <> String.pad_leading(Integer.to_string(sequence), @padding, "0")

  defp dropped_key(agent_id), do: agent_id <> "/dropped"

  @doc "The namespace events are written under in `Wardrik.Store`."
  @spec namespace() :: Store.ns()
  def namespace, do: @ns
end
