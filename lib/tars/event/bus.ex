defmodule Tars.Event.Bus do
  @moduledoc """
  Fan-out for agent events.

  Publishers name the agent an event belongs to and know nothing about who is
  listening: there may be no subscribers, one, or several UIs attached to the
  same agent. Subscribe with `subscribe/2` and receive `t:Tars.Event.t/0`
  structs as plain messages.

  Each event goes two places:

    * **Telemetry**, for instrumentation. Handlers run in the emitting process
      and are permanently detached if they raise, which is fine for metrics and
      disqualifying for user-visible output. Telemetry sees every event at
      every level.

    * **The fleet's `Group`**, for delivery, or a local `Registry` when the
      fleet is not running. A subscriber that dies is unregistered
      automatically, and a broken handler cannot switch the stream off for
      everyone else.

  Dispatch runs in the calling process, so each subscriber observes one
  publisher's events in emission order. `send/2` never blocks, so a slow
  subscriber cannot slow a turn, though its mailbox will grow.

  ## Across the cluster

  With `Tars.Fleet` running, subscriptions are `Group` memberships and reach
  subscribers on any connected node, so a terminal here can watch an agent
  running three nodes away. Without it, delivery is local.

  Which one is in use is fixed when the application starts, so a subscriber and
  a publisher never disagree about where events go. A subscriber must
  resubscribe if the fleet or the local registry restarts.

  ## Levels

  A subscription names how much of the stream it wants, as a
  `t:Tars.Event.level/0`. `:activity` is what an agent is doing; `:raw` adds
  the provider's own stream records, which repeat it token by token.

      Tars.Event.Bus.subscribe("_/_/assistant")                  # :activity
      Tars.Event.Bus.subscribe("_/_/assistant", level: :raw)     # everything

  `Tars.Event.level/1` decides where a type sits, so a type added later
  reaches existing subscribers without them naming it. Each level is its own
  topic and a `:raw` subscriber holds both, so every event arrives once.

  Telemetry events are named `[:tars, :agent, type]`, where `type` is
  `Tars.Event.type/1`. Their metadata carries the agent id, the span, and the
  event itself.
  """

  alias Tars.Event
  alias Tars.Fleet

  @registry Tars.Event.Bus.Registry

  @default_level :activity

  @typedoc "What subscribers subscribe to. An agent's fleet key, or its pid."
  @type agent_id() :: term()

  @typedoc "Where events are delivered: across the cluster, or on this node only."
  @type transport() :: :cluster | :local

  @doc false
  @spec put_transport(transport()) :: :ok
  def put_transport(transport) when transport in [:cluster, :local] do
    :persistent_term.put({__MODULE__, :transport}, transport)
  end

  @doc "Where this node delivers events. Set when the application starts."
  @spec transport() :: transport()
  def transport, do: :persistent_term.get({__MODULE__, :transport}, :local)

  @doc false
  def child_spec(_opts) do
    Registry.child_spec(keys: :duplicate, name: @registry)
  end

  @doc """
  Receive `agent_id`'s events as plain messages in the calling process.

  Options:

    * `:level` - how much of the stream to take, `#{inspect(@default_level)}` by default

  Subscriptions are dropped automatically when the subscriber exits.
  """
  @spec subscribe(agent_id(), keyword()) :: :ok
  def subscribe(agent_id, opts \\ []) do
    level = level!(opts)

    if clustered?() do
      Enum.each(topics(level), &Group.join(Fleet, topic(agent_id, &1), %{level: level}))
    else
      {:ok, _pid} = Registry.register(@registry, agent_id, level)
    end

    :ok
  end

  defp level!(opts) do
    level = Keyword.get(opts, :level, @default_level)

    unless level in Event.levels() do
      raise ArgumentError,
            "unknown level #{inspect(level)}, expected one of #{inspect(Event.levels())}"
    end

    level
  end

  @spec unsubscribe(agent_id()) :: :ok
  def unsubscribe(agent_id) do
    if clustered?() do
      Enum.each(Event.levels(), &Group.leave(Fleet, topic(agent_id, &1)))
    else
      Registry.unregister(@registry, agent_id)
    end

    :ok
  end

  @spec subscribers(agent_id()) :: [pid()]
  def subscribers(agent_id) do
    if clustered?() do
      Event.levels()
      |> Enum.flat_map(&Group.members(Fleet, topic(agent_id, &1)))
      |> Enum.map(&elem(&1, 0))
      |> Enum.uniq()
    else
      @registry |> Registry.lookup(agent_id) |> Enum.map(&elem(&1, 0))
    end
  end

  @doc """
  Deliver an event to everyone watching its source's agent at a level that takes it.

  Usually reached through `Tars.Event.emit/2` rather than called directly.
  """
  @spec publish(Event.t()) :: :ok
  def publish(%Event{source: source} = event) do
    type = Event.type(event)

    :telemetry.execute(
      [:tars, :agent, type],
      %{system_time: event.at},
      %{
        agent_id: source.agent_id,
        trace_id: source.trace.trace_id,
        span_id: source.trace.span_id,
        parent_span_id: source.trace.parent_span_id,
        event: event
      }
    )

    if clustered?() do
      Group.dispatch(Fleet, topic(source.agent_id, Event.level(type)), event)
    else
      Registry.dispatch(@registry, source.agent_id, &deliver(&1, type, event))
    end
  end

  defp deliver(subscribers, type, event) do
    subscribers
    |> Enum.filter(fn {_pid, level} -> Event.delivers?(level, type) end)
    |> Enum.each(fn {pid, _level} -> send(pid, event) end)
  end

  # A `:raw` subscriber holds both topics, so an activity event dispatched to
  # the activity topic reaches every subscriber exactly once.
  defp topics(:activity), do: [:activity]
  defp topics(:raw), do: [:activity, :raw]

  defp topic(agent_id, level), do: "tars/events/#{ident(agent_id)}/#{level}"

  defp ident(agent_id) when is_binary(agent_id), do: agent_id
  defp ident(agent_id) when is_atom(agent_id), do: Atom.to_string(agent_id)
  defp ident(pid) when is_pid(pid), do: "#{node(pid)}#{:erlang.pid_to_list(pid)}"
  defp ident(other), do: inspect(other)

  defp clustered?, do: transport() == :cluster
end
