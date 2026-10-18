defmodule WardrikTrigger.Server do
  @moduledoc """
  The process behind one `WardrikTrigger`: it sleeps until the trigger's next
  run, writes down the run after it, checks the trigger's source, and asks
  the agent with what it found, writing down the source's cursor first.

  Started by `WardrikTrigger.put/2` under the supervisor `WardrikTrigger`
  runs.
  """

  use DurableServer, vsn: 1

  alias WardrikTrigger.Delivery
  alias WardrikTrigger.State

  require Logger

  # A timer is re-armed at least this often, so a clock that jumps, or a host
  # that slept, is noticed within the hour.
  @max_sleep :timer.hours(1)

  @impl DurableServer
  def dump_state(%State{} = state),
    do: state |> Map.from_struct() |> Map.drop([:host, :settings])

  @impl DurableServer
  def load_state(_old_vsn, dumped), do: struct!(State, dumped)

  # DurableServer's callback type leaves out the continue its server takes
  # from `init`.
  @dialyzer {:nowarn_function, init: 2}
  @impl DurableServer
  def init(%State{} = state, %{host: host, settings: settings}) do
    state = %{state | host: host, settings: settings}
    :ok = WardrikTrigger.join(state.agent, state.trigger)
    {:ok, state, {:continue, :wake}, meta: State.meta(state), permanent: true}
  end

  # Each step after a write is a continue, so no call lands between a run
  # written down and its delivery.
  @impl DurableServer
  def handle_call({:configure, %WardrikTrigger{} = trigger}, _from, state) do
    next = State.configure(state, trigger, DateTime.utc_now())
    {:reply, :ok, next, {:continue, :wake}, meta: State.meta(next), sync: true}
  end

  @impl DurableServer
  def handle_continue(:wake, state), do: wake(state)

  # Runs after the state naming the next run has been written, so a crash
  # from here on loses this firing rather than repeating it. The cursor is
  # written before the agent is asked, for the same reason.
  def handle_continue(:deliver, state) do
    case check(state) do
      {:ask, pid, items, cursor} ->
        next = %{state | cursor: cursor}
        {:noreply, next, {:continue, {:ask, pid, items}}, meta: State.meta(next), sync: true}

      {outcome, cursor} ->
        settle(%{state | cursor: cursor}, outcome)
    end
  end

  def handle_continue({:ask, pid, items}, %State{trigger: trigger} = state) do
    :ok = Delivery.ask(pid, trigger.prompt, items)
    settle(state, :asked)
  end

  @impl DurableServer
  def handle_info({:wake, tag}, state) do
    if Process.get(:wake) == tag, do: wake(state), else: {:noreply, state}
  end

  defp wake(state) do
    case State.due(state, DateTime.utc_now()) do
      {:wait, ms} ->
        arm(ms)
        {:noreply, state}

      {:fire, next} ->
        {:noreply, next, {:continue, :deliver}, meta: State.meta(next), sync: true}

      {:skip, next} ->
        announce(next, :missed)
        {:noreply, next, {:continue, :wake}, meta: State.meta(next), sync: true}
    end
  end

  defp settle(state, outcome) do
    announce(state, outcome)
    next = State.fired(state, outcome)
    {:noreply, next, {:continue, :wake}, meta: State.meta(next), sync: true}
  end

  # The source is checked before the agent is looked up, so a source with
  # nothing new wakes no sleeping agent; and its cursor is kept only once the
  # agent is asked, so what an agent that was busy missed is found again.
  defp check(%State{agent: agent, trigger: trigger, cursor: cursor, settings: settings} = state) do
    case WardrikTrigger.check(trigger, cursor, agent: agent, settings: settings) do
      {:ok, [], next} ->
        {:nothing_new, next}

      {:ok, items, next} ->
        case Delivery.ready(agent, trigger.overlap, host: state.host) do
          {:ok, pid} -> {:ask, pid, items, next}
          outcome -> {outcome, cursor}
        end

      {:error, reason} ->
        Logger.warning("trigger #{agent}//#{trigger.name} could not check: #{reason}")
        {:failed, cursor}
    end
  end

  defp announce(%State{agent: agent, trigger: trigger}, outcome),
    do: Delivery.announce(agent, trigger.name, outcome)

  # Only the timer armed last wakes the trigger.
  defp arm(ms) do
    tag = make_ref()
    Process.put(:wake, tag)
    Process.send_after(self(), {:wake, tag}, min(ms, @max_sleep))
  end
end
