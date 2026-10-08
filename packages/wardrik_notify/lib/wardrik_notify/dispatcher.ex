defmodule WardrikNotify.Dispatcher do
  @moduledoc """
  Holds each agent's `WardrikNotify.Route`, subscribes to the agent's events,
  and hands each `WardrikNotify.Notice` its route asks for to every target, one
  task per delivery.

  A notice is sent only by the node holding the agent at the time, so every
  node of a cluster can route the same agents and each notice goes out once.

  It is started with the targets and the request options
  `WardrikNotify.Supervisor` takes.

  `:routes` is where it finds the routes as it starts, so one that restarts
  routes what it routed before: a `{module, function, args}` or a function of
  no arguments returning the routes `put_routes/1` takes. It starts with none
  without it.

  A delivery a target fails, or that crashes, is tried again after a second,
  then after two, and is given up with a warning after the third attempt.
  A target `config.yaml` does not configure, or that does not tell the
  agent's org, is not tried again. `:backoff` sets the first wait, in
  milliseconds.
  """

  use GenServer

  require Logger

  alias WardrikNotify.Notice
  alias WardrikNotify.Route

  @tasks WardrikNotify.TaskSupervisor
  @attempts 3

  @typedoc "Each routed agent's route."
  @type routes() :: %{Wardrik.AgentID.t() => Route.t()}

  @typedoc "Where the routes are found as it starts."
  @type source() :: {module(), atom(), [term()]} | (-> routes())

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    opts = Keyword.validate!(opts, routes: nil, backoff: 1_000, targets: [], req_options: [])

    state = %{
      routes: %{},
      deliveries: %{},
      backoff: opts[:backoff],
      targets: opts[:targets],
      req_options: opts[:req_options]
    }

    GenServer.start_link(__MODULE__, {opts[:routes], state}, name: __MODULE__)
  end

  @doc false
  @spec put_routes(routes()) :: :ok
  def put_routes(routes), do: GenServer.call(__MODULE__, {:routes, routes})

  @impl true
  def init({nil, state}), do: {:ok, state}
  def init({source, state}), do: {:ok, state, {:continue, {:load, source}}}

  @impl true
  def handle_continue({:load, {module, function, args}}, state),
    do: {:noreply, route(state, apply(module, function, args))}

  def handle_continue({:load, source}, state) when is_function(source, 0),
    do: {:noreply, route(state, source.())}

  @impl true
  def handle_call({:routes, routes}, _from, state), do: {:reply, :ok, route(state, routes)}

  @impl true
  def handle_info(%Wardrik.Event{source: %{agent_id: agent}} = event, state) do
    with %Route{} = route <- Map.get(state.routes, agent),
         {:ok, %Notice{} = notice} <- Notice.from_event(event),
         true <- notice.kind in route.on,
         true <- held_here?(agent) do
      {:noreply, Enum.reduce(route.targets, state, &send_to(&2, &1, notice, 1))}
    else
      _not_sent -> {:noreply, state}
    end
  end

  def handle_info({ref, result}, state) when is_map_key(state.deliveries, ref) do
    Process.demonitor(ref, [:flush])
    {delivery, state} = pop_in(state.deliveries[ref])
    {:noreply, delivered(state, delivery, result)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state)
      when is_map_key(state.deliveries, ref) do
    {delivery, state} = pop_in(state.deliveries[ref])
    {:noreply, delivered(state, delivery, {:error, {:crashed, reason}})}
  end

  def handle_info({:retry, timer}, state) when is_map_key(state.deliveries, timer) do
    {{target, notice, attempt}, state} = pop_in(state.deliveries[timer])
    {:noreply, send_to(state, target, notice, attempt)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp route(%{routes: current} = state, routes) when is_map(routes) do
    for agent <- Map.keys(current),
        not Map.has_key?(routes, agent),
        do: Wardrik.Event.Bus.unsubscribe(agent)

    for agent <- Map.keys(routes),
        not Map.has_key?(current, agent),
        do: Wardrik.Event.Bus.subscribe(agent, level: :lifecycle)

    %{state | routes: routes}
  end

  defp held_here?(agent) do
    case Wardrik.Fleet.whereis(agent) do
      pid when is_pid(pid) -> node(pid) == node()
      nil -> false
    end
  end

  # Each delivery, and each wait before one is tried again, is held under
  # its ref until it is done.
  defp send_to(state, name, notice, attempt) do
    settings = Map.take(state, [:targets, :req_options])

    %Task{ref: ref} =
      Task.Supervisor.async_nolink(@tasks, fn -> deliver(name, notice, settings) end)

    put_in(state.deliveries[ref], {name, notice, attempt})
  end

  defp deliver(name, notice, %{targets: targets, req_options: req_options}) do
    with {:ok, {module, opts}} <- WardrikNotify.target(targets, name),
         true <- WardrikNotify.tells?(targets, name, notice.agent.org) do
      opts = opts |> Keyword.put(:target, name) |> Keyword.put_new(:req_options, req_options)
      module.deliver(notice, opts)
    else
      :error -> {:skip, "which config.yaml does not configure"}
      false -> {:skip, "which tells another org's agents"}
    end
  end

  defp delivered(state, _delivery, :ok), do: state

  defp delivered(state, {name, notice, _attempt}, {:skip, why}) do
    Logger.warning("#{notice.agent} routes to #{name}, #{why}")
    state
  end

  defp delivered(state, {name, notice, attempt}, {:error, reason}) when attempt < @attempts do
    Logger.warning(failed(name, notice, reason) <> "; trying again")
    timer = make_ref()
    Process.send_after(self(), {:retry, timer}, state.backoff * 2 ** (attempt - 1))
    put_in(state.deliveries[timer], {name, notice, attempt + 1})
  end

  defp delivered(state, {name, notice, _attempt}, {:error, reason}) do
    Logger.warning(failed(name, notice, reason) <> "; giving up")
    state
  end

  defp failed(name, notice, reason),
    do: "Could not tell #{name} that #{notice.agent} #{notice.kind}: #{inspect(reason)}"
end
