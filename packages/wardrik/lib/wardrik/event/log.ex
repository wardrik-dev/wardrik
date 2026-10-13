defmodule Wardrik.Event.Log do
  @moduledoc """
  Each agent's events as CloudEvents, numbered and kept, so a client can
  resume from the last one it saw, on any node and across a `kill -9`.

      {:ok, events} = Wardrik.Event.Log.read(store, ~A"acme/triage", starting_after: 40)

  A log is an agent's, named by its ID, or `:audit`, what people changed,
  which `Wardrik.Audit` writes. Each is read, followed and trimmed alike.

  ## Written by the agent alone

  An agent's log has one writer. `Wardrik.Agent` is one process per ID across the cluster, and it is its log's
  only writer, through a `Wardrik.Event.Log.Writer`. It follows its own events,
  encodes each with `Wardrik.Event.Codec`, and writes the durable ones to
  the host's `WardrikStore` under the next sequence number, in the order they reach it. A
  write is conditional on nothing being written under that number yet, so two
  owners of one agent can never both write it.

  Sequence numbers start at 1, run without a gap, and are never reused under
  one agent, even one forgotten and started again under the same ID.

  ## Following it live

  `subscribe/1` delivers every event the writer numbers, durable and live, as
  a `Wardrik.Event.Log.Entry`, in the order it numbered them, to a subscriber on
  any node. Live events, the text and reasoning deltas and tool progress, are
  delivered and never written.

  A client that resumes subscribes first, then reads from the last sequence it
  saw, then takes the entries that follow what it read; see
  `Wardrik.Event.Log.Entry.follows?/2`.

  ## Reading it

  Every read and write is handed the store the log is kept in.

  `read/3` answers the events after a sequence number, oldest first. A read
  from before what the log still holds answers `{:gap, oldest}`, and the client
  starts again from the agent's snapshot, which carries the head sequence.

  `logs/1` lists every log written to, a forgotten agent's included, which
  `Wardrik.Event.Export` reads from end to end.

  ## Retention

  Events are kept 30 days. After each run the agent drops those older than
  that, never past the last event it wrote, so an open run keeps every event
  it has.
  """

  alias Wardrik.Event.Log.Entry

  @ns :events

  # Each agent whose log has been opened, by its ID's text.
  @logs :event_logs

  @retention_days 30

  @default_limit 500

  @padding 12

  @typedoc "A log: an agent's, by its ID, or `:audit`."
  @type log() :: Wardrik.AgentID.t() | :audit

  defguardp log?(log) when is_struct(log, Wardrik.AgentID) or log == :audit

  @doc false
  def child_spec([]), do: Group.child_spec(name: __MODULE__)

  @doc "How long events are kept, in days."
  @spec retention_days() :: pos_integer()
  def retention_days, do: @retention_days

  @doc """
  The events of `log` after a sequence number, oldest first.

  Options:

    * `:starting_after` - the last sequence already seen, `0` for all
    * `:limit` - how many to answer at most, #{@default_limit} by default
    * `:consistent` - `false` reads this node's copy of the store alone, which
      may end before the log does; `true` by default, which reads the end
      again through consensus

  Answers `{:gap, oldest}` when events after `:starting_after` have been
  dropped, where `oldest` is the first one still held.
  """
  @spec read(WardrikStore.t(), log(), keyword()) :: {:ok, [map()]} | {:gap, pos_integer()}
  def read(store, log, opts \\ []) when log?(log) do
    next = Keyword.get(opts, :starting_after, 0) + 1
    oldest = oldest(store, log)

    if next < oldest,
      do: {:gap, oldest},
      else: {:ok, take(store, log, next, opts)}
  end

  # Reads by number stop at the first one missing here. It is read again
  # through consensus before it is taken as the end, since this node's copy of
  # the store may be behind the node that wrote it.
  defp take(store, log, sequence, opts) do
    confirm = Keyword.get(opts, :consistent, true)

    Stream.unfold({sequence, Keyword.get(opts, :limit, @default_limit)}, fn
      {_sequence, 0} ->
        nil

      {sequence, limit} ->
        key = key(log, sequence)

        case WardrikStore.get(store, @ns, key) || confirmed(store, key, confirm) do
          nil -> nil
          event -> {event, {sequence + 1, limit - 1}}
        end
    end)
    |> Enum.to_list()
  end

  defp confirmed(store, key, true), do: WardrikStore.get(store, @ns, key, consistent: true)
  defp confirmed(_store, _key, false), do: nil

  @doc """
  Writes `agent_id` down among the logs `logs/1` lists. Its writer's to call
  as it opens the log.
  """
  @spec opened(WardrikStore.t(), Wardrik.AgentID.t()) :: :ok | {:error, term()}
  def opened(store, %Wardrik.AgentID{} = agent_id) do
    with {:ok, _vsn} <- WardrikStore.put(store, @logs, to_string(agent_id), true), do: :ok
  end

  @doc "Every log written to: `:audit`, then each agent's, by its ID's text."
  @spec logs(WardrikStore.t()) :: [log()]
  def logs(store) do
    agents =
      store |> WardrikStore.keys(@logs) |> Enum.sort() |> Enum.map(&Wardrik.AgentID.parse!/1)

    [:audit | agents]
  end

  @doc """
  Subscribes the calling process to the entries written to `log`, as
  `Wardrik.Event.Log.Entry` messages.
  """
  @spec subscribe(log()) :: :ok
  def subscribe(log) when log?(log), do: Group.join(__MODULE__, to_string(log), %{})

  @spec unsubscribe(log()) :: :ok
  def unsubscribe(log) when log?(log), do: Group.leave(__MODULE__, to_string(log))

  @doc "Delivers an entry to every subscriber to `log`. A writer's to call."
  @spec publish(log(), Entry.t()) :: :ok
  def publish(log, %Entry{} = entry) when log?(log),
    do: Group.dispatch(__MODULE__, to_string(log), entry)

  @doc """
  Drops the events of `log` written before `cutoff`, oldest first, and none
  after the sequence `through`.
  """
  @spec trim(WardrikStore.t(), log(), non_neg_integer(), DateTime.t()) ::
          :ok | {:error, term()}
  def trim(store, log, through, %DateTime{} = cutoff) when log?(log) do
    {dropped, vsn} = lookup_dropped(store, log)

    case expired_through(store, log, dropped, through, cutoff) do
      ^dropped ->
        :ok

      last ->
        with :ok <- put_dropped(store, log, last, vsn), do: drop(store, log, dropped + 1, last)
    end
  end

  defp expired_through(store, log, sequence, through, cutoff) do
    next = sequence + 1

    with true <- next <= through,
         %{"time" => time} <- WardrikStore.get(store, @ns, key(log, next)),
         {:ok, at, _offset} <- DateTime.from_iso8601(time),
         :lt <- DateTime.compare(at, cutoff) do
      expired_through(store, log, next, through, cutoff)
    else
      _kept -> sequence
    end
  end

  # What has been dropped is written down before the events go, so a read never
  # finds them missing without being told of the gap.
  defp put_dropped(store, log, last, vsn) do
    case WardrikStore.put(store, @ns, dropped_key(log), last, if_vsn: vsn) do
      {:ok, _vsn} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp drop(store, log, first, last) do
    Enum.reduce_while(first..last//1, :ok, fn sequence, :ok ->
      key = key(log, sequence)

      case WardrikStore.lookup(store, @ns, key) do
        {_event, vsn} -> WardrikStore.delete(store, @ns, key, if_vsn: vsn) |> continue()
        nil -> {:cont, :ok}
      end
    end)
  end

  defp continue(:ok), do: {:cont, :ok}
  defp continue({:error, reason}), do: {:halt, {:error, reason}}

  @doc """
  The first sequence `log` still holds, or would hold: `1` until events have
  been dropped. `consistent: true` reads it through consensus.
  """
  @spec oldest(WardrikStore.t(), log(), keyword()) :: pos_integer()
  def oldest(store, log, opts \\ []) when log?(log),
    do: (WardrikStore.get(store, @ns, dropped_key(log), opts) || 0) + 1

  defp lookup_dropped(store, log) do
    case WardrikStore.lookup(store, @ns, dropped_key(log)) do
      {dropped, vsn} -> {dropped, vsn}
      nil -> {0, nil}
    end
  end

  @doc """
  The last sequence written to `log` above `known`, a sequence known to be
  written or dropped, read through consensus.

  The numbers a log holds are written without a gap, so a gallop forward
  finds a number past the head, and a bisection back finds the head.
  """
  @spec head(WardrikStore.t(), log(), non_neg_integer()) :: non_neg_integer()
  def head(store, log, known) when log?(log) and is_integer(known) and known >= 0,
    do: gallop(store, log, known, 1)

  defp gallop(store, log, known, step) do
    if written?(store, log, known + step),
      do: gallop(store, log, known + step, step * 2),
      else: bisect(store, log, known, known + step)
  end

  defp bisect(_store, _log, known, missing) when missing - known <= 1, do: known

  defp bisect(store, log, known, missing) do
    middle = div(known + missing, 2)

    if written?(store, log, middle),
      do: bisect(store, log, middle, missing),
      else: bisect(store, log, known, middle)
  end

  defp written?(store, log, sequence),
    do: WardrikStore.get(store, @ns, key(log, sequence), consistent: true) != nil

  @doc "The store key the event of `log` at `sequence` is written under."
  @spec key(log(), pos_integer()) :: WardrikStore.key()
  def key(log, sequence),
    do: "#{log}//" <> String.pad_leading(Integer.to_string(sequence), @padding, "0")

  defp dropped_key(log), do: "#{log}//dropped"

  @doc "The namespace events are written under in `WardrikStore`."
  @spec namespace() :: WardrikStore.ns()
  def namespace, do: @ns
end
