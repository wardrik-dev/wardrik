defmodule WardrikNotify.Dispatcher do
  @moduledoc """
  Holds each agent's `WardrikNotify.Route`, subscribes to the agent's events,
  and hands each `WardrikNotify.Notice` its route asks for to every target, one
  task per delivery.

  A notice is sent only by the node holding the agent at the time, so every
  node of a cluster can route the same agents and each notice goes out once.

  `:routes` is where it finds the routes as it starts, so one that restarts
  routes what it routed before: a `{module, function, args}` or a function of
  no arguments returning the routes `put_routes/1` takes. It starts with none
  without it.
  """

  use GenServer

  require Logger

  alias WardrikNotify.Notice
  alias WardrikNotify.Route

  @tasks WardrikNotify.TaskSupervisor

  @typedoc "Each routed agent's route."
  @type routes() :: %{Wardrik.AgentID.t() => Route.t()}

  @typedoc "Where the routes are found as it starts."
  @type source() :: {module(), atom(), [term()]} | (-> routes())

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    opts = Keyword.validate!(opts, routes: nil)
    GenServer.start_link(__MODULE__, opts[:routes], name: __MODULE__)
  end

  @doc false
  @spec put_routes(routes()) :: :ok
  def put_routes(routes), do: GenServer.call(__MODULE__, {:routes, routes})

  @impl true
  def init(nil), do: {:ok, %{}}
  def init(source), do: {:ok, %{}, {:continue, {:load, source}}}

  @impl true
  def handle_continue({:load, {module, function, args}}, current),
    do: {:noreply, route(current, apply(module, function, args))}

  def handle_continue({:load, source}, current) when is_function(source, 0),
    do: {:noreply, route(current, source.())}

  @impl true
  def handle_call({:routes, routes}, _from, current), do: {:reply, :ok, route(current, routes)}

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

  defp route(current, routes) when is_map(routes) do
    for agent <- Map.keys(current),
        not Map.has_key?(routes, agent),
        do: Wardrik.Event.Bus.unsubscribe(agent)

    for agent <- Map.keys(routes),
        not Map.has_key?(current, agent),
        do: Wardrik.Event.Bus.subscribe(agent, level: :lifecycle)

    routes
  end

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
