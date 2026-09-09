defmodule Tars.Events do
  @moduledoc """
  Fan-out for agent stream and tool events.

  Emitting code calls `emit/2` with the id of the agent the event belongs to and
  knows nothing about who is listening — there may be no subscribers, one, or
  several UIs attached to the same agent.

  Each event goes two places, deliberately:

    * **Telemetry**, for instrumentation. Handlers run in the emitting process
      and are permanently detached if they raise, which is fine for metrics and
      disqualifying for user-visible output.

    * **A duplicate-key `Registry`**, for delivery. A subscriber that dies is
      unregistered automatically, and a broken handler cannot switch the stream
      off for everyone else.

  Dispatch runs in the calling process, so each subscriber observes events in
  emission order. `send/2` never blocks, so a slow subscriber cannot slow a
  turn — though its mailbox will grow.

  Telemetry events are named `[:tars, :agent, kind]`, where `kind` is the
  event's leading element: `:chunk`, `:meta`, `:result`, `:thinking`,
  `:tool_call`, `:tool_started`, `:tool_finished`.
  """

  @registry Tars.Events.Registry

  @type agent_id() :: term()
  @type event() :: tuple()

  @doc false
  def child_spec(_opts) do
    Registry.child_spec(keys: :duplicate, name: @registry)
  end

  @doc """
  Receive `agent_id`'s events as plain messages in the calling process.

  Subscriptions are dropped automatically when the subscriber exits.
  """
  @spec subscribe(agent_id()) :: :ok
  def subscribe(agent_id) do
    {:ok, _pid} = Registry.register(@registry, agent_id, [])
    :ok
  end

  @spec unsubscribe(agent_id()) :: :ok
  def unsubscribe(agent_id), do: Registry.unregister(@registry, agent_id)

  @spec subscribers(agent_id()) :: [pid()]
  def subscribers(agent_id) do
    @registry |> Registry.lookup(agent_id) |> Enum.map(&elem(&1, 0))
  end

  @spec emit(agent_id(), event()) :: :ok
  def emit(agent_id, event) when is_tuple(event) do
    :telemetry.execute(
      [:tars, :agent, elem(event, 0)],
      %{system_time: System.system_time()},
      %{agent_id: agent_id, event: event}
    )

    Registry.dispatch(@registry, agent_id, fn subscribers ->
      Enum.each(subscribers, fn {pid, _value} -> send(pid, event) end)
    end)
  end
end
