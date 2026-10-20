defmodule Wardrik.Event.Log do
  @moduledoc """
  Each agent's events as CloudEvents, numbered and kept, so a reader can
  resume from the last one it saw, on any node and across a `kill -9`.
  `Wardrik.events/2` reads them and `Wardrik.subscribe/2` follows them; the
  functions here are theirs, and the writers'.

      {:ok, events} = Wardrik.Event.Log.read(store, ~A"acme/triage", starting_after: 40)

  A log is an agent's, named by its ID, or `:audit`, what people changed,
  which `Wardrik.Audit` writes. Each is read and trimmed alike, and an
  agent's is followed.

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

  A subscriber names the agents it follows by `Wardrik.Resource` pattern,
  and the CloudEvent types it takes. Every entry a writer numbers, durable
  and live, reaches each subscriber with a pattern covering its agent once,
  as a `Wardrik.Event.Log.Entry`, in the order it numbered them, on any
  node. Live events, the text and reasoning deltas and tool progress, are
  delivered and never written.

  Subscriptions are memberships of a `Group`, holding their patterns and
  types: a pattern that names its org joins that org's topic, and one with a
  wildcard there, as `*/agent/triage`, the topic of every org. A writer sends
  each entry to the members of both that cover its agent, matching a
  wildcard anywhere as written. A process is a member of a topic once, with
  every pattern it subscribed to there.

  ## Reading it

  Every read and write is handed the store the log is kept in.

  A read answers the events after a sequence number, oldest first, and one
  from before what the log still holds, `{:gap, oldest}`.

  A stream reads every log a reader's patterns cover from its positions,
  page by page, then follows them; `heads/2` are the positions of a reader
  starting from now. It subscribes before it reads, and takes
  only the entries that follow what it read (`Wardrik.Event.Log.Entry.follows?/2`),
  so it sees each event once, in order; an entry that follows events it has
  not read, as an agent's first after the reader listed the logs, reads
  those first. Where a log was trimmed past where it reads, it takes the
  `wardrik.events.dropped` event of `Wardrik.Event.Codec.dropped/2`, whatever
  types it takes, and reads on from the oldest event held.

  ## Retention

  Events are kept 30 days. After each run the agent drops those older than
  that, never past the last event it wrote, so an open run keeps every event
  it has.
  """

  alias Wardrik.AgentID
  alias Wardrik.Event.Codec
  alias Wardrik.Event.Log.Entry
  alias Wardrik.Resource

  @ns :events

  # Each agent whose log has been opened, by its resource name.
  @logs :event_logs

  @retention_days 30

  @default_limit 500

  @padding 12

  # The topic of the patterns that name no org.
  @every_org "*"

  @typedoc "A log: an agent's, by its ID, or `:audit`."
  @type log() :: AgentID.t() | :audit

  @typedoc "The CloudEvent types a reader takes, or every one."
  @type types() :: [String.t()] | :all

  defguardp log?(log) when is_struct(log, AgentID) or log == :audit

  @doc false
  def child_spec([]), do: Group.child_spec(name: __MODULE__)

  @doc "How long events are kept, in days."
  @spec retention_days() :: pos_integer()
  def retention_days, do: @retention_days

  # The events of `log` after `:starting_after`, `0` for all, oldest first,
  # at most `:limit`. `consistent: false` reads this node's copy of the store
  # alone, which may end before the log does. `{:gap, oldest}` where events
  # after `:starting_after` have been dropped.
  @doc false
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
  Writes `agent_id` down among the logs a reader lists. Its writer's to call
  as it opens the log.
  """
  @spec opened(WardrikStore.t(), AgentID.t()) :: :ok | {:error, term()}
  def opened(store, %AgentID{} = agent_id) do
    with {:ok, _vsn} <- WardrikStore.put(store, @logs, name(agent_id), true), do: :ok
  end

  @doc "Every log written to: `:audit`, then each agent's, by its resource name."
  @spec logs(WardrikStore.t()) :: [log()]
  def logs(store) do
    agents = store |> WardrikStore.keys(@logs) |> Enum.sort() |> Enum.map(&agent!/1)
    [:audit | agents]
  end

  # The logs of the agents `resources` covers, by name: every one written
  # to, a forgotten agent's included.
  defp covered(store, resources) do
    for prefix <- resources |> Enum.map(&Resource.prefix/1) |> Enum.uniq(),
        key <- store |> WardrikStore.keys(@logs, prefix) |> Enum.sort(),
        resource = Resource.parse!(key),
        Enum.any?(resources, &Resource.covers?(&1, resource)),
        uniq: true,
        do: agent!(key)
  end

  defp agent!(key) do
    {:ok, id} = key |> Resource.parse!() |> AgentID.from_resource()
    id
  end

  @doc """
  The last sequence written to each log `resources` covers, read through
  consensus: where a reader starts that takes what is written from now and
  resumes from its cursor.
  """
  @spec heads(WardrikStore.t(), [Resource.t()]) :: Wardrik.Event.Cursor.positions()
  def heads(store, resources) do
    Map.new(covered(store, resources), fn log ->
      {log, head(store, log, oldest(store, log, consistent: true) - 1)}
    end)
  end

  @doc false
  @spec subscribe(AgentID.t()) :: :ok
  def subscribe(%AgentID{} = agent_id), do: subscribe([AgentID.resource(agent_id)], :all)

  @doc false
  @spec subscribe([Resource.t()], types()) :: :ok
  def subscribe(resources, types) do
    for {topic, resources} <- Enum.group_by(resources, &topic/1) do
      held = Map.merge(held(topic), Map.new(resources, &{&1, types}), &both/3)
      :ok = Group.join(__MODULE__, topic, held)
    end

    :ok
  end

  defp both(_pattern, :all, _types), do: :all
  defp both(_pattern, _types, :all), do: :all
  defp both(_pattern, types, more), do: Enum.uniq(types ++ more)

  @doc false
  @spec unsubscribe(AgentID.t() | [Resource.t()]) :: :ok
  def unsubscribe(%AgentID{} = agent_id), do: unsubscribe([AgentID.resource(agent_id)])

  def unsubscribe(resources) do
    for {topic, resources} <- Enum.group_by(resources, &topic/1) do
      case Map.drop(held(topic), resources) do
        held when map_size(held) == 0 -> Group.leave(__MODULE__, topic)
        held -> Group.join(__MODULE__, topic, held)
      end
    end

    :ok
  end

  # The patterns this process holds of `topic`, with the types each takes.
  defp held(topic) do
    Enum.find_value(Group.local_members(__MODULE__, topic), %{}, fn {pid, held} ->
      pid == self() and held
    end)
  end

  # The org a pattern names, or every org's topic where it begins with a
  # wildcard.
  defp topic(%Resource{name: name}) do
    [first | _rest] = String.split(name, "/", parts: 2)
    if String.contains?(first, ["*", "?"]), do: @every_org, else: first
  end

  @doc false
  @spec publish(Entry.t()) :: :ok
  def publish(%Entry{log: %AgentID{} = agent_id, event: %{"type" => type}} = entry) do
    resource = AgentID.resource(agent_id)

    pids =
      for topic <- [@every_org, agent_id.org],
          {pid, held} <- Group.members(__MODULE__, topic),
          Enum.any?(held, fn {pattern, types} ->
            takes?(types, type) and Resource.covers?(pattern, resource)
          end),
          uniq: true,
          do: pid

    Enum.each(pids, &send(&1, entry))
  end

  # A gap reaches every reader, whatever types it takes, so none passes it
  # by unawares.
  defp takes?(_types, "wardrik.events.dropped"), do: true
  defp takes?(:all, _type), do: true
  defp takes?(types, type), do: type in types

  @doc false
  @spec stream(WardrikStore.t(), [Resource.t()],
          after: Wardrik.Event.Cursor.positions() | :head,
          follow: boolean(),
          types: types()
        ) :: Enumerable.t(Entry.t())
  def stream(store, resources, opts) do
    opts = Keyword.validate!(opts, [:after, :follow, :types])
    types = Keyword.fetch!(opts, :types)

    Stream.resource(
      fn ->
        open(store, resources, Keyword.fetch!(opts, :after), Keyword.fetch!(opts, :follow))
      end,
      &next(store, &1),
      &close(resources, &1)
    )
    |> Stream.filter(&takes?(types, &1.event["type"]))
  end

  # What a stream reads, from where, and what then: nothing more, or what
  # it follows, taking a log it has not read from `start` of its first entry.
  defp open(_store, resources, :head, follow),
    do: {[], %{}, following(resources, follow, & &1.follows)}

  defp open(store, resources, positions, follow) do
    then = following(resources, follow, fn _entry -> 0 end)
    {covered(store, resources), positions, then}
  end

  defp following(resources, true, start) do
    :ok = subscribe(resources, :all)
    {:follow, start}
  end

  defp following(_resources, false, _start), do: :halt

  defp next(store, {[log | logs], positions, then}) do
    case page(store, log, Map.get(positions, log, 0), then != :halt) do
      {[], _at} -> next(store, {logs, positions, then})
      {entries, at} -> {entries, {[log | logs], Map.put(positions, log, at), then}}
    end
  end

  defp next(_store, {[], _positions, :halt} = state), do: {:halt, state}

  defp next(store, {[], positions, {:follow, start} = then}) do
    receive do
      %Entry{} = entry ->
        {entries, positions} = arrived(store, entry, positions, start)
        {entries, {[], positions, then}}
    end
  end

  # A page of `log` after `at`, as entries, and the sequence it reaches. A
  # stream that follows reads through consensus, so its reads reach every
  # event written before it subscribed.
  defp page(store, log, at, consistent) do
    case read(store, log, starting_after: at, limit: @default_limit, consistent: consistent) do
      {:ok, events} ->
        {Entry.numbered(events, log, at), at + length(events)}

      {:gap, oldest} ->
        event = Codec.dropped(log, after: at, oldest: oldest)
        {[%Entry{log: log, event: event, follows: oldest - 1}], oldest - 1}
    end
  end

  defp arrived(store, %Entry{log: log} = entry, positions, start) do
    at = Map.get_lazy(positions, log, fn -> start.(entry) end)
    {read, at} = if entry.follows > at, do: catch_up(store, log, at), else: {[], at}

    if Entry.follows?(entry, at),
      do: {read ++ [entry], Map.put(positions, log, entry.sequence || entry.follows)},
      else: {read, Map.put(positions, log, at)}
  end

  defp catch_up(store, log, at) do
    case page(store, log, at, true) do
      {[], at} ->
        {[], at}

      {entries, at} ->
        {more, at} = catch_up(store, log, at)
        {entries ++ more, at}
    end
  end

  defp close(resources, {_logs, _positions, {:follow, _start}}) do
    unsubscribe(resources)
    flush()
  end

  defp close(_resources, _state), do: :ok

  defp flush do
    receive do
      %Entry{} -> flush()
    after
      0 -> :ok
    end
  end

  @doc """
  Drops the events of `log` written before `opts[:before]`, oldest first,
  and none after the sequence `opts[:through]`.

      Log.trim(store, log, through: head, before: cutoff)
  """
  @spec trim(WardrikStore.t(), log(), through: non_neg_integer(), before: DateTime.t()) ::
          :ok | {:error, term()}
  def trim(store, log, opts) when log?(log) do
    opts = Keyword.validate!(opts, [:through, :before])
    %DateTime{} = cutoff = Keyword.fetch!(opts, :before)
    through = Keyword.fetch!(opts, :through)
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
    do: name(log) <> "//" <> String.pad_leading(Integer.to_string(sequence), @padding, "0")

  defp dropped_key(log), do: name(log) <> "//dropped"

  defp name(:audit), do: "audit"
  defp name(%AgentID{} = agent_id), do: to_string(AgentID.resource(agent_id))

  @doc "The namespace events are written under in `WardrikStore`."
  @spec namespace() :: WardrikStore.ns()
  def namespace, do: @ns
end
