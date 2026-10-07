defmodule WardrikNotify.Dispatcher do
  @moduledoc """
  Holds each agent's `WardrikNotify.Route`, subscribes to the agent's events,
  and hands each `WardrikNotify.Notice` its route asks for to every target, one
  task per delivery.

  A notice is sent only by the node holding the agent at the time, so every
  node of a cluster can route the same agents and each notice goes out once.
  """

  use GenServer

  require Logger

  alias WardrikNotify.Notice
  alias WardrikNotify.Route

  @tasks WardrikNotify.TaskSupervisor

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  @doc false
  @spec put_routes(%{Wardrik.AgentID.t() => Route.t()}) :: :ok
  def put_routes(routes), do: GenServer.call(__MODULE__, {:routes, routes})

  @impl true
  def init(routes), do: {:ok, routes}

  @impl true
  def handle_call({:routes, routes}, _from, current) do
    for agent <- Map.keys(current),
        not Map.has_key?(routes, agent),
        do: Wardrik.Event.Bus.unsubscribe(agent)

    for agent <- Map.keys(routes),
        not Map.has_key?(current, agent),
        do: Wardrik.Event.Bus.subscribe(agent, level: :lifecycle)

    {:reply, :ok, routes}
  end

  @impl true
  def handle_info(%Wardrik.Event{source: %{agent_id: agent}} = event, routes) do
    with %Route{} = route <- Map.get(routes, agent),
         {:ok, %Notice{} = notice} <- Notice.from_event(event),
         true <- notice.kind in route.on,
         true <- held_here?(agent) do
      Enum.each(route.targets, &send_to(&1, notice))
    end

    {:noreply, routes}
  end

  def handle_info(_message, routes), do: {:noreply, routes}

  defp held_here?(agent) do
    case Wardrik.Fleet.whereis(agent) do
      pid when is_pid(pid) -> node(pid) == node()
      nil -> false
    end
  end

  defp send_to(name, notice) do
    Task.Supervisor.start_child(@tasks, fn -> deliver(name, notice) end)
  end

  defp deliver(name, notice) do
    with {:ok, {module, opts}} <- WardrikNotify.Config.target(name),
         true <- WardrikNotify.Config.tells?(name, notice.agent.org),
         :ok <- module.deliver(notice, Keyword.put(opts, :target, name)) do
      :ok
    else
      :error ->
        Logger.warning("#{notice.agent} routes to #{name}, which config.yaml does not configure")

      false ->
        Logger.warning("#{notice.agent} routes to #{name}, which tells another org's agents")

      {:error, reason} ->
        Logger.warning(
          "Could not tell #{name} that #{notice.agent} #{notice.kind}: #{inspect(reason)}"
        )
    end
  end
end
