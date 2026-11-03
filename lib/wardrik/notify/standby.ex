defmodule Wardrik.Notify.Standby do
  @moduledoc false

  # Keeps one notifier running among every node on a store, clustered or not.
  #
  # Nodes that share a store without being clustered are the normal case for a while in most
  # deploys: a blue-green swap or a rolling restart runs the old release and the new one side by
  # side on one database. The new node then finds the notifier's lock held by a process it can't
  # see. That isn't an error, so it stands by and claims the notifier once the other node lets
  # go. Nothing tells a node on another cluster when that happens, so it asks the store again on
  # an interval. Where the notifier runs on a node it can see, it watches that process instead.

  use GenServer

  require Logger

  alias Wardrik.Notify.Server

  @interval 2_000
  @attempt_timeout 500

  @spec start_link(atom()) :: GenServer.on_start()
  def start_link(supervisor), do: GenServer.start_link(__MODULE__, supervisor)

  @impl GenServer
  def init(supervisor) do
    # The first claim runs before Wardrik finishes starting, so a node that's alone on its store
    # runs the notifier as soon as it boots.
    {:ok, claim(%{supervisor: supervisor, watching: nil, waiting?: false})}
  end

  @impl GenServer
  def handle_info(:claim, state), do: {:noreply, claim(state)}

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{watching: ref} = state),
    do: {:noreply, claim(%{state | watching: nil})}

  def handle_info(_message, state), do: {:noreply, state}

  defp claim(state) do
    case Server.claim(state.supervisor, @attempt_timeout) do
      {:ok, {pid, _meta}} ->
        %{state | watching: Process.monitor(pid), waiting?: false}

      {:error, reason} ->
        if not state.waiting?, do: Logger.info(waiting(reason))
        Process.send_after(self(), :claim, @interval)
        %{state | waiting?: true}
    end
  end

  defp waiting({:unreachable, _pid}),
    do: "The notifier runs on a node this one isn't clustered with; standing by to take it over."

  defp waiting(reason), do: "Couldn't start the notifier yet (#{inspect(reason)}); trying again."
end
