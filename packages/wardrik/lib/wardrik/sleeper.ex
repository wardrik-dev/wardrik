defmodule Wardrik.Sleeper do
  @moduledoc false

  use GenServer

  require Logger

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
  def watch(wardrik, id),
    do: GenServer.cast(Module.concat(wardrik.name, Sleeper), {:watch, {id, nil}})

  @impl GenServer
  def init(wardrik) do
    {:ok, tasks} = Task.Supervisor.start_link()
    {:ok, %{wardrik: wardrik, tasks: tasks, timers: %{}, digests: %{}}, {:continue, :subscribe}}
  end

  @impl GenServer
  def handle_continue(:subscribe, %{wardrik: wardrik} = state) do
    :ok = WardrikEvents.subscribe(Wardrik.events(wardrik), :all)
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
      {:ok, ^ref} -> {:noreply, digest(%{state | timers: Map.delete(timers, id)}, id)}
      _stale -> {:noreply, state}
    end
  end

  def handle_info({ref, result}, %{digests: digests} = state) when is_map_key(digests, ref) do
    Process.demonitor(ref, [:flush])
    {id, digests} = Map.pop!(digests, ref)
    if match?({:error, _reason}, result), do: failed(id, result)
    {:noreply, sleep(%{state | digests: digests}, id)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{digests: digests} = state)
      when is_map_key(digests, ref) do
    {id, digests} = Map.pop!(digests, ref)
    failed(id, reason)
    {:noreply, sleep(%{state | digests: digests}, id)}
  end

  defp arm(%{wardrik: wardrik} = state, {agent, _conversation} = id) do
    with {:ok, definition} <- Running.definition(wardrik, agent),
         ms when is_integer(ms) <- Wardrik.Resolution.idle_timeout(wardrik, agent, definition) do
      ref = make_ref()
      Process.send_after(self(), {:sleep, id, ref}, ms)
      %{state | timers: Map.put(state.timers, id, ref)}
    else
      _never -> state
    end
  end

  defp disarm(state, id), do: %{state | timers: Map.delete(state.timers, id)}

  # The digest runs in a task. The agent sleeps when it's done, written or not.
  defp digest(%{wardrik: wardrik} = state, {agent, _conversation} = id) do
    with pid when is_pid(pid) <- Running.whereis(wardrik, id),
         :idle <- WardrikCore.status(pid),
         {:ok, definition} <- Running.definition(wardrik, agent),
         true <- Wardrik.Resolution.digest?(wardrik, agent, definition) do
      task = Task.Supervisor.async_nolink(state.tasks, Wardrik.Digest, :write, [wardrik, id, pid])
      %{state | digests: Map.put(state.digests, task.ref, id)}
    else
      _no_digest -> sleep(state, id)
    end
  end

  defp failed(id, reason),
    do: Logger.warning("#{Running.describe(id)} didn't write its digest: #{inspect(reason)}")

  defp sleep(%{wardrik: wardrik} = state, id) do
    with pid when is_pid(pid) <- Running.whereis(wardrik, id),
         :idle <- WardrikCore.status(pid) do
      WardrikCore.stop(pid)
    end

    state
  end
end
