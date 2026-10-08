defmodule WardrikSchedule.Server do
  @moduledoc """
  The process behind one `WardrikSchedule`: it sleeps until the schedule's next
  run, writes down the run after it, and then asks the agent.

  Started by `WardrikSchedule.put/2` under the supervisor `WardrikSchedule`
  runs.
  """

  use DurableServer, vsn: 1

  alias Wardrik.Agent
  alias Wardrik.Event
  alias Wardrik.Fleet
  alias WardrikSchedule.State

  # A timer is re-armed at least this often, so a clock that jumps, or a host
  # that slept, is noticed within the hour.
  @max_sleep :timer.hours(1)

  @impl DurableServer
  def dump_state(%State{} = state), do: Map.from_struct(state)

  @impl DurableServer
  def load_state(_old_vsn, dumped), do: struct!(State, dumped)

  # DurableServer's callback type leaves out the continue its server takes
  # from `init`.
  @dialyzer {:nowarn_function, init: 1}
  @impl DurableServer
  def init(%State{} = state) do
    :ok = WardrikSchedule.join(state.agent, state.schedule.name)
    {:ok, state, {:continue, :wake}, meta: State.meta(state), permanent: true}
  end

  # Each step after a write is a continue, so no call lands between a run
  # written down and its delivery.
  @impl DurableServer
  def handle_call({:configure, %WardrikSchedule{} = schedule}, _from, state) do
    next = State.configure(state, schedule, DateTime.utc_now())
    {:reply, :ok, next, {:continue, :wake}, meta: State.meta(next), sync: true}
  end

  @impl DurableServer
  def handle_continue(:wake, state), do: wake(state)

  # Runs after the state naming the next run has been written, so a crash
  # from here on loses this firing rather than repeating it.
  def handle_continue(:deliver, state) do
    outcome = deliver(state)
    announce(state, outcome)
    next = State.fired(state, outcome)
    {:noreply, next, {:continue, :wake}, meta: State.meta(next), sync: true}
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

  defp deliver(%State{agent: agent, schedule: schedule}) do
    case Fleet.whereis(agent) do
      nil -> :no_agent
      pid -> ask(pid, schedule)
    end
  catch
    :exit, _reason -> :failed
  end

  defp ask(pid, %WardrikSchedule{overlap: :queue, prompt: prompt}) do
    :ok = Agent.ask(pid, prompt)
    :asked
  end

  defp ask(pid, %WardrikSchedule{overlap: :skip, prompt: prompt}) do
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
    Event.announce(agent, {:schedule_fired, schedule.name, outcome})
  end

  # Only the timer armed last wakes the schedule.
  defp arm(ms) do
    tag = make_ref()
    Process.put(:wake, tag)
    Process.send_after(self(), {:wake, tag}, min(ms, @max_sleep))
  end
end
