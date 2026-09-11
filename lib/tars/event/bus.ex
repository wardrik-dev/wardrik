defmodule Tars.Event.Bus do
  @moduledoc """
  Fan-out for agent events.

  Publishers name the agent an event belongs to and know nothing about who is
  listening: there may be no subscribers, one, or several UIs attached to the
  same agent. Subscribe with `subscribe/2` and receive `t:Tars.Event.t/0`
  structs as plain messages.

  Each event goes two places, deliberately:

    * **Telemetry**, for instrumentation. Handlers run in the emitting process
      and are permanently detached if they raise, which is fine for metrics and
      disqualifying for user-visible output. Telemetry sees every event at
      every level.

    * **A duplicate-key `Registry`**, for delivery. A subscriber that dies is
      unregistered automatically, and a broken handler cannot switch the stream
      off for everyone else.

  Dispatch runs in the calling process, so each subscriber observes one
  publisher's events in emission order. `send/2` never blocks, so a slow
  subscriber cannot slow a turn, though its mailbox will grow.

  ## Levels

  A subscription names how much of the stream it wants, as a
  `t:Tars.Event.level/0`. `:activity` is what an agent is doing; `:raw` adds
  the provider's own stream records, which repeat it token by token.

      Tars.Event.Bus.subscribe(:assistant)                  # :activity
      Tars.Event.Bus.subscribe(:assistant, level: :raw)     # everything

  `Tars.Event.level/1` decides where a type sits, so a type added later
  reaches existing subscribers without them naming it.

  Telemetry events are named `[:tars, :agent, type]`, where `type` is
  `Tars.Event.type/1`. Their metadata carries the agent id, the span, and the
  event itself.
  """

  alias Tars.Event

  @registry Tars.Event.Bus.Registry

  @default_level :activity

  @typedoc "What subscribers subscribe to. An agent's registered name, or its pid."
  @type agent_id() :: term()

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
    level = Keyword.get(opts, :level, @default_level)

    unless level in Event.levels() do
      raise ArgumentError,
            "unknown level #{inspect(level)}, expected one of #{inspect(Event.levels())}"
    end

    {:ok, _pid} = Registry.register(@registry, agent_id, level)
    :ok
  end

  @spec unsubscribe(agent_id()) :: :ok
  def unsubscribe(agent_id), do: Registry.unregister(@registry, agent_id)

  @spec subscribers(agent_id()) :: [pid()]
  def subscribers(agent_id) do
    @registry |> Registry.lookup(agent_id) |> Enum.map(&elem(&1, 0))
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

    Registry.dispatch(@registry, source.agent_id, &deliver(&1, type, event))
  end

  defp deliver(subscribers, type, event) do
    subscribers
    |> Enum.filter(fn {_pid, level} -> Event.delivers?(level, type) end)
    |> Enum.each(fn {pid, _level} -> send(pid, event) end)
  end
end
