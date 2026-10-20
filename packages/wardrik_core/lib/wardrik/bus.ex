defmodule Wardrik.Bus do
  @moduledoc """
  Fan-out for agent events.

  Publishers name the agent an event belongs to and know nothing about who is
  listening: there may be no subscribers, one, or several UIs attached to the
  same agent. A renderer in the same VM, as the TUI is, subscribes and
  receives `t:Wardrik.Event.t/0` structs as plain messages; an application
  follows the CloudEvents of `Wardrik.subscribe/2` instead.

  Each event goes two places:

    * **Telemetry**, for instrumentation. Handlers run in the emitting process
      and are permanently detached if they raise, which is fine for metrics and
      disqualifying for user-visible output. Telemetry sees every event at
      every level.

    * **A `Group` of its own**, for delivery. Subscriptions are memberships and
      reach subscribers on any connected node, so a terminal here can watch an
      agent running three nodes away. A subscriber that dies is unregistered
      automatically, and a broken handler cannot switch the stream off for
      everyone else.

  Dispatch runs in the calling process, so each subscriber observes one
  publisher's events in emission order. `send/2` never blocks, so a slow
  subscriber cannot slow a turn, though its mailbox will grow.

  ## Levels

  A subscription names how much of the stream it wants, as a
  `t:Wardrik.Event.level/0`. `:activity` is what an agent is doing; `:raw` adds
  the provider's own stream records, which repeat it token by token.

      Wardrik.Bus.subscribe(~A"acme/assistant")                # :activity
      Wardrik.Bus.subscribe(~A"acme/assistant", level: :raw)   # everything

  `Wardrik.Event.level/1` decides where a type sits, so a type added later
  reaches existing subscribers without them naming it. Each level is its own
  topic and a `:raw` subscriber holds both, so every event arrives once.

  Telemetry events are named `[:wardrik, :agent, type]`, where `type` is
  `Wardrik.Event.type/1`. Their metadata carries the agent id, the span, and the
  event itself.
  """

  alias Wardrik.Bus.Event

  @group __MODULE__

  @default_level :activity

  @typedoc "What subscribers subscribe to: an agent's or a thread's address."
  @type agent_id() :: Wardrik.AgentAddress.t()

  @doc false
  def child_spec([]), do: Group.child_spec(name: @group)

  # Subscribes the calling process to an agent's events, at `:level`, a
  # `t:Wardrik.Event.level/0`, `:activity` by default. `:lifecycle` is the
  # shape of the work alone, cheap enough to hold for many agents.
  @doc false
  @spec subscribe(agent_id(), keyword()) :: :ok
  def subscribe(agent_id, opts \\ []) do
    level = level!(opts)

    Enum.each(topics(level), &Group.join(@group, topic(agent_id, &1), %{level: level}))
  end

  defp level!(opts) do
    level = Keyword.get(opts, :level, @default_level)

    unless level in Event.levels() do
      raise ArgumentError,
            "unknown level #{inspect(level)}, expected one of #{inspect(Event.levels())}"
    end

    level
  end

  @doc false
  @spec unsubscribe(agent_id()) :: :ok
  def unsubscribe(agent_id) do
    Enum.each(Event.levels(), &Group.leave(@group, topic(agent_id, &1)))
  end

  @doc false
  @spec subscribers(agent_id()) :: [pid()]
  def subscribers(agent_id) do
    Event.levels()
    |> Enum.flat_map(&Group.members(@group, topic(agent_id, &1)))
    |> Enum.map(&elem(&1, 0))
    |> Enum.uniq()
  end

  @doc """
  Deliver an event to everyone watching its source's agent at a level that takes it.

  Usually reached through `Wardrik.Event.emit/2` rather than called directly.
  """
  @spec publish(Event.t()) :: :ok
  def publish(%Event{source: source} = event) do
    type = Event.type(event)

    :telemetry.execute(
      [:wardrik, :agent, type],
      %{system_time: event.at},
      %{
        agent_id: source.agent_id,
        trace_id: source.trace.trace_id,
        span_id: source.trace.span_id,
        parent_span_id: source.trace.parent_span_id,
        event: event
      }
    )

    Group.dispatch(@group, topic(source.agent_id, Event.level(type)), event)
  end

  # A subscriber holds the topic of its level and every level below, so an
  # event dispatched to its own level's topic reaches every subscriber once.
  defp topics(level) do
    Enum.take_while(Event.levels(), &(&1 != level)) ++ [level]
  end

  defp topic(agent_id, level), do: "#{agent_id}/#{level}"
end
