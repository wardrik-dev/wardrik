defmodule Wardrik.Sleeper do
  @moduledoc """
  Puts defined agents to sleep after their idle timeout. An agent wakes when something asks it.
  """

  use GenServer

  alias Wardrik.Operations.Running

  @idle ~w(wardrik.agent.started wardrik.run.completed wardrik.run.failed wardrik.run.cancelled
           wardrik.run.deadline_exceeded)
  @busy ~w(wardrik.message.created wardrik.run.started wardrik.run.resumed wardrik.run.interrupted
           wardrik.agent.stopped)

  @doc "Starts the sleeper."
  @spec start_link(Wardrik.t()) :: GenServer.on_start()
  def start_link(wardrik),
    do: GenServer.start_link(__MODULE__, wardrik, name: Module.concat(wardrik.name, Sleeper))

  @doc "Starts the idle timer for the newly defined agent `id`."
  @spec watch(Wardrik.t(), String.t()) :: :ok
  def watch(wardrik, id), do: GenServer.cast(Module.concat(wardrik.name, Sleeper), {:watch, id})

  @impl GenServer
  def init(wardrik), do: {:ok, %{wardrik: wardrik, timers: %{}}, {:continue, :subscribe}}

  @impl GenServer
  def handle_continue(:subscribe, %{wardrik: wardrik} = state) do
    :ok = WardrikEvents.subscribe(Wardrik.events(wardrik), ["*"])
    {:noreply, state}
  end

  @impl GenServer
  def handle_cast({:watch, id}, state), do: {:noreply, state |> disarm(id) |> arm(id)}

  @impl GenServer
  def handle_info({WardrikEvents, id, %{"type" => type}}, state) when type in @idle,
    do: {:noreply, state |> disarm(id) |> arm(id)}

  def handle_info({WardrikEvents, id, %{"type" => type}}, state) when type in @busy,
    do: {:noreply, disarm(state, id)}

  def handle_info({WardrikEvents, _id, _event}, state), do: {:noreply, state}

  def handle_info({:sleep, id, ref}, %{timers: timers} = state) do
    case Map.fetch(timers, id) do
      {:ok, ^ref} -> {:noreply, sleep(%{state | timers: Map.delete(timers, id)}, id)}
      _stale -> {:noreply, state}
    end
  end

  defp arm(%{wardrik: wardrik} = state, id) do
    with {:ok, definition} <- Running.definition(wardrik, id),
         ms when is_integer(ms) <- Wardrik.Resolution.idle_timeout(wardrik, id, definition) do
      ref = make_ref()
      Process.send_after(self(), {:sleep, id, ref}, ms)
      %{state | timers: Map.put(state.timers, id, ref)}
    else
      _never -> state
    end
  end

  defp disarm(state, id), do: %{state | timers: Map.delete(state.timers, id)}

  defp sleep(%{wardrik: wardrik} = state, id) do
    with pid when is_pid(pid) <- Running.whereis(wardrik, id),
         :idle <- WardrikCore.status(pid) do
      WardrikCore.stop(pid)
    end

    state
  end
end
