defmodule WardrikNotify.Keeper do
  @moduledoc """
  Where `WardrikNotify` has got to in the agents' logs, and what tells of
  them from there: one process in the cluster, a `DurableServer` keyed
  `"notify"`, which carries on from its cursor on another node when its
  own is lost.

  It acts as the deployment, `Wardrik.Principal.deployment/0`, which the
  host's `Wardrik.Issuer` allows `agent.events` on every agent, as
  `*/agent/*`; a host that does not fails to start it. The first time it
  starts it takes the head of every agent's log, `Wardrik.events_head/2`,
  so it tells of what is written from then on.

  It runs `WardrikNotify.Listener`, and a task supervisor its deliveries
  run under, and writes down the cursor the listener hands it past each
  event before the listener goes on. A notice whose delivery a lost node
  cut short is sent again from there, so each is sent at least once.

  `WardrikNotify.Supervisor` starts it, or finds it running on another
  node.
  """

  use DurableServer, vsn: 1

  alias Wardrik.Principal

  @key "notify"

  @types ~w(wardrik.run.interrupted wardrik.run.failed wardrik.run.completed)

  @doc """
  Starts the keeper under the `DurableServer.Supervisor` named
  `supervisor`, or finds the one the cluster runs, as a supervisor starts
  a child: `:ignore` once it runs.
  """
  @spec start(atom()) :: :ignore | {:error, term()}
  def start(supervisor) do
    child = {__MODULE__, key: @key, initial_state: %{cursor: :head}}

    with {:ok, _held} <- DurableServer.Supervisor.ensure_started_child(supervisor, child),
         do: :ignore
  end

  @doc "Writes down `cursor`, past the event the listener of `keeper` has told of."
  @spec saved(pid(), String.t()) :: :ok
  def saved(keeper, cursor), do: GenServer.call(keeper, {:saved, cursor})

  @impl DurableServer
  def dump_state(%{cursor: cursor}), do: %{cursor: cursor}

  @impl DurableServer
  def load_state(_old_vsn, %{cursor: cursor}), do: %{cursor: cursor}

  # DurableServer's callback type leaves out the continue its server takes
  # from `init`. The head is taken here, before the keeper answers that it
  # started, so a host whose issuer does not allow it fails to start it.
  @dialyzer {:nowarn_function, init: 2}
  @impl DurableServer
  def init(%{cursor: cursor}, %{host: host} = info) do
    resources = [Wardrik.Resource.parse!("*/agent/*")]
    cursor = head(cursor, Wardrik.as(host, Principal.deployment()), resources)
    {:ok, tasks} = Task.Supervisor.start_link()

    listener =
      [
        host: host,
        principal: Principal.deployment(),
        after: cursor,
        resources: resources,
        types: @types,
        keeper: self(),
        tasks: tasks
      ] ++ Map.to_list(Map.take(info, [:targets, :req_options, :backoff]))

    {:ok, _listening} =
      Supervisor.start_link([{WardrikNotify.Listener, listener}], strategy: :one_for_one)

    {:ok, %{cursor: cursor}, {:continue, :keep}, permanent: true}
  end

  defp head(:head, scope, resources), do: Wardrik.events_head!(scope, resources: resources)
  defp head(cursor, _scope, _resources), do: cursor

  @impl DurableServer
  def handle_continue(:keep, state), do: {:noreply, state, sync: true}

  @impl DurableServer
  def handle_call({:saved, cursor}, _from, state),
    do: {:reply, :ok, %{state | cursor: cursor}, sync: true}

  # The listener's supervisor, or the deliveries', gave up: the keeper
  # starts again, from the cursor it wrote down.
  @impl DurableServer
  def handle_info({:EXIT, _pid, reason}, state), do: {:stop, {:error, reason}, state}
end
