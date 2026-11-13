defmodule Wardrik.Triggers.Scheduler do
  @moduledoc false

  use GenServer

  alias Wardrik.Triggers.Clock
  alias Wardrik.Triggers.Records
  alias Wardrik.Triggers.Run
  alias Wardrik.Triggers.Trigger

  @longest :timer.hours(24)

  @doc "Starts the scheduler."
  @spec start_link(map()) :: GenServer.on_start()
  def start_link(settings),
    do: GenServer.start_link(__MODULE__, settings, name: settings.scheduler)

  @impl GenServer
  def init(settings), do: {:ok, %{settings: settings, timers: %{}}, {:continue, :reconcile}}

  @impl GenServer
  def handle_continue(:reconcile, state) do
    tick(state.settings)
    {:noreply, reconcile(state)}
  end

  @impl GenServer
  def handle_call(:reconcile, _from, state), do: {:reply, :ok, reconcile(state)}

  def handle_call({:set, agent_id, trigger}, _from, state) do
    case set(state.settings, agent_id, trigger) do
      {:ok, record} ->
        {:reply, {:ok, trigger}, arm(state, {agent_id, trigger.name}, Records.next_at(record))}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:remove, agent_id, name}, _from, state) do
    case Records.lookup(state.settings.store, agent_id: agent_id, name: name) do
      nil ->
        {:reply, {:error, :not_found}, state}

      {_record, _vsn} ->
        case Records.delete(state.settings.store, agent_id: agent_id, name: name) do
          :ok -> {:reply, :ok, disarm(state, {agent_id, name})}
          error -> {:reply, error, state}
        end
    end
  end

  @impl GenServer
  def handle_info(:reconcile, state) do
    tick(state.settings)
    {:noreply, reconcile(state)}
  end

  def handle_info({:due, key, ref}, %{timers: timers} = state) do
    case Map.fetch(timers, key) do
      {:ok, ^ref} -> {:noreply, due(%{state | timers: Map.delete(timers, key)}, key)}
      _stale -> {:noreply, state}
    end
  end

  defp set(settings, agent_id, trigger) do
    now = DateTime.utc_now()

    case Records.lookup(settings.store, agent_id: agent_id, name: trigger.name) do
      nil ->
        record = %{
          "agent_id" => agent_id,
          "trigger" => Trigger.encode(trigger),
          "next_at" => upcoming(trigger, now),
          "last_at" => nil
        }

        with :ok <- Records.put(settings.store, record, nil), do: {:ok, record}

      {record, vsn} ->
        record = changed(record, trigger, now)
        with :ok <- Records.put(settings.store, record, vsn), do: {:ok, record}
    end
  end

  defp changed(record, trigger, now) do
    kept = Records.trigger(record)

    next_at =
      if {kept.every, kept.at, kept.timezone} == {trigger.every, trigger.at, trigger.timezone},
        do: record["next_at"],
        else: upcoming(trigger, now)

    %{record | "trigger" => Trigger.encode(trigger), "next_at" => next_at}
  end

  defp reconcile(%{settings: settings} = state) do
    Enum.reduce(Records.all(settings.store), state, fn {agent_id, name} = key, state ->
      case Records.lookup(settings.store, agent_id: agent_id, name: name) do
        {record, _vsn} -> arm(state, key, Records.next_at(record))
        nil -> state
      end
    end)
  end

  defp due(%{settings: settings} = state, {agent_id, name} = key) do
    case Records.lookup(settings.store, agent_id: agent_id, name: name) do
      nil -> state
      {record, vsn} -> claim(state, key, record, vsn, DateTime.utc_now())
    end
  end

  defp claim(state, key, record, vsn, now) do
    due = Records.next_at(record)

    if due == nil or DateTime.after?(due, now),
      do: arm(state, key, due),
      else: run(state, key, record, vsn, due, now)
  end

  defp run(%{settings: settings} = state, {agent_id, _name} = key, record, vsn, due, now) do
    trigger = Records.trigger(record)

    claimed = %{
      record
      | "next_at" => following(trigger, now),
        "last_at" => DateTime.to_iso8601(now)
    }

    case Records.put(settings.store, claimed, vsn) do
      :ok ->
        Task.Supervisor.start_child(settings.tasks, Run, :clock, [
          settings,
          [agent_id: agent_id, trigger: trigger, due: due, now: now]
        ])

        arm(state, key, Records.next_at(claimed))

      {:error, _taken} ->
        due(state, key)
    end
  end

  defp following(%Trigger{clock: {:at, _at}}, _now), do: nil
  defp following(trigger, now), do: upcoming(trigger, now)

  defp upcoming(%Trigger{clock: nil}, _now), do: nil

  defp upcoming(%Trigger{clock: clock, timezone: timezone, jitter: jitter}, now) do
    case Clock.next(clock, timezone, now) do
      nil ->
        nil

      next ->
        next
        |> DateTime.add(jittered(jitter))
        |> DateTime.to_iso8601()
    end
  end

  defp jittered(0), do: 0
  defp jittered(jitter), do: :rand.uniform(jitter + 1) - 1

  defp arm(state, key, nil), do: disarm(state, key)

  defp arm(state, key, next_at) do
    ref = make_ref()

    delay =
      next_at
      |> DateTime.diff(DateTime.utc_now(), :millisecond)
      |> max(0)
      |> min(@longest)

    Process.send_after(self(), {:due, key, ref}, delay)
    %{state | timers: Map.put(state.timers, key, ref)}
  end

  defp disarm(state, key), do: %{state | timers: Map.delete(state.timers, key)}

  defp tick(%{reconcile: :infinity}), do: :ok
  defp tick(%{reconcile: ms}), do: Process.send_after(self(), :reconcile, ms)
end
