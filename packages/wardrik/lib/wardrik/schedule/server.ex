defmodule Wardrik.Schedule.Server do
  @moduledoc """
  The process behind one `Wardrik.Schedule`: it sleeps until the schedule's next
  run, writes down the run after it, and then asks the agent.

  Started by `Wardrik.Schedule.put/2` under the `Wardrik.Schedules` supervisor that
  `Wardrik.Fleet.Supervisor` runs.
  """

  use DurableServer, vsn: 1

  alias Wardrik.Agent
  alias Wardrik.Event
  alias Wardrik.Event.Source
  alias Wardrik.Fleet
  alias Wardrik.Schedule
  alias Wardrik.Schedule.State

  # A timer is re-armed at least this often, so a clock that jumps, or a host
  # that slept, is noticed within the hour.
  @max_sleep :timer.hours(1)

  @impl DurableServer
  def dump_state(%State{} = state), do: Map.from_struct(state)

  @impl DurableServer
  def load_state(_old_vsn, dumped), do: struct!(State, dumped)

  @impl DurableServer
  def init(%State{} = state) do
    wake_now()
    {:ok, state, meta: State.meta(state), permanent: true}
  end

  @impl DurableServer
  def handle_call({:configure, %Schedule{} = schedule}, _from, state) do
    next = State.configure(state, schedule, DateTime.utc_now())
    wake_now()
    {:reply, :ok, next, meta: State.meta(next), sync: true}
  end

  @impl DurableServer
  def handle_info({:wake, tag}, state) do
    if Process.get(:wake) == tag, do: wake(state), else: {:noreply, state}
  end

  # Runs after the state naming the next run has been written, so a crash
  # from here on loses this firing rather than repeating it.
  def handle_info(:deliver, state) do
    outcome = deliver(state)
    announce(state, outcome)
    next = State.fired(state, outcome)
    wake_now()
    {:noreply, next, meta: State.meta(next), sync: true}
  end

  defp wake(state) do
    case State.due(state, DateTime.utc_now()) do
      {:wait, ms} ->
        arm(ms)
        {:noreply, state}

      {:fire, next} ->
        send(self(), :deliver)
        {:noreply, next, meta: State.meta(next), sync: true}

      {:skip, next} ->
        announce(next, :missed)
        wake_now()
        {:noreply, next, meta: State.meta(next), sync: true}
    end
  end

  defp deliver(%State{agent: agent, schedule: schedule}) do
    case Fleet.whereis(agent) do
      nil -> :no_agent
      pid -> ask(pid, schedule)
    end
  catch
    :exit, _reason -> :failed
  end

  defp ask(pid, %Schedule{overlap: :queue, prompt: prompt}) do
    :ok = Agent.ask(pid, prompt)
    :asked
  end

  defp ask(pid, %Schedule{overlap: :skip, prompt: prompt}) do
    case Agent.status(pid) do
      %{state: :idle} ->
        :ok = Agent.ask(pid, prompt)
        :asked

      %{state: _running_or_parked} ->
        :busy

      {:error, :not_found} ->
        :no_agent
    end
  end

  defp announce(%State{agent: agent, schedule: schedule}, outcome) do
    Event.emit(Source.root(agent), {:schedule_fired, schedule.name, outcome})
  end

  defp wake_now, do: arm(0)

  # Only the timer armed last wakes the schedule.
  defp arm(ms) do
    tag = make_ref()
    Process.put(:wake, tag)
    Process.send_after(self(), {:wake, tag}, min(ms, @max_sleep))
  end
end
