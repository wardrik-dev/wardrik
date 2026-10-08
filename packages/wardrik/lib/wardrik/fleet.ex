defmodule Wardrik.Fleet do
  @moduledoc """
  Every agent in the cluster: what is running, what it is doing, and how to
  stop it.

  | Function | Answers |
  | --- | --- |
  | `put/1` | start an agent from its `Wardrik.Agent.Spec`, or bring a running one to it |
  | `list/1` | which agents are running, and what each is doing |
  | `watch/1` | the same, as messages, whenever it changes |
  | `kill/1` | interrupt everything under a prefix |
  | `forget/1`, `forget_under/1` | remove an agent, or every agent under a prefix, and its store |
  | `move/2` | restart an agent on another node, as it was |
  | `whereis/1` | the pid behind an ID, on whatever node holds it |
  | `stored?/1` | whether the store holds an agent, running or stopped |

  An agent is addressed by its `Wardrik.AgentID`, and the fleet is sliced by
  `Wardrik.AgentID.Prefix`:

      Wardrik.Fleet.list()                                         # everything
      Wardrik.Fleet.list(Wardrik.AgentID.Prefix.new!(org: "acme"))  # one tenant

  ## Listing

  Agents publish what they are doing as registry metadata when it changes, and
  the registry replicates between nodes, so `list/1` is a table read that sends
  no messages and `watch/1` needs no polling.

  ## Durability

  Agents are `DurableServer` processes: one per ID across the cluster under a
  lock, state written to the store on every change that matters, and restarted
  on another node when theirs is lost. See `Wardrik.Agent.State` for what survives
  a restart and what does not. The registry knows each agent by its ID's text.
  """

  alias Wardrik.Agent
  alias Wardrik.Agent.Spec
  alias Wardrik.AgentID
  alias Wardrik.AgentID.Prefix
  alias Wardrik.Fleet.Member

  @name __MODULE__
  @prefix "agents/"

  @doc false
  @spec prefix() :: String.t()
  def prefix, do: @prefix

  # -- lifecycle -------------------------------------------------------------

  @doc """
  Starts an agent in the fleet, or returns the one already running under its ID.

  Options are everything `Wardrik.Agent.initial_state/2` takes, and `:node`, the
  node to start it on. Without one the agent is placed on whichever node has
  capacity, so the pid may be remote either way.

      {:ok, pid} = Wardrik.Fleet.spawn(Wardrik.AgentID.new!("researcher", org: "acme"), config: config)
      {:ok, pid} = Wardrik.Fleet.spawn(id, config: config, node: :"wardrik_b@host")
  """
  @spec spawn(AgentID.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def spawn(%AgentID{} = id, opts \\ []) do
    {node, opts} = Keyword.pop(opts, :node)

    child(id, opts) |> start(node) |> started()
  end

  @doc """
  Makes the fleet match `spec`: starts the agent it describes where none runs
  under its ID, gives the one that does the spec's config and seams with
  `Wardrik.Agent.configure/2`. The agent keeps its conversation either way.

      {:ok, pid} = Wardrik.Fleet.put(Wardrik.Agent.Spec.new(id: Wardrik.AgentID.new!("triage", org: "acme")))
  """
  @spec put(Spec.t()) :: {:ok, pid()} | {:error, term()}
  def put(%Spec{} = spec) do
    options = Spec.options(spec)

    with {:ok, pid} <- spawn(spec.id, options),
         :ok <- Agent.configure(pid, options) do
      {:ok, pid}
    end
  end

  @doc """
  Stops an agent and starts it again on `node`, with the state it had.

      {:ok, pid} = Wardrik.Fleet.move(~A"acme/@jon/researcher", :"wardrik_b@host")
  """
  @spec move(AgentID.t(), node()) :: {:ok, pid()} | {:error, term()}
  def move(%AgentID{} = id, node) when is_atom(node) do
    @name
    |> DurableServer.Supervisor.rehome_child(child(id, []), target_node: node)
    |> started()
  end

  defp child(id, opts),
    do: {Agent, key: to_string(id), initial_state: Agent.initial_state(opts, id)}

  defp start(child, nil), do: DurableServer.Supervisor.ensure_started_child(@name, child)

  defp start(child, node) do
    args = [@name, child, [local_only: true]]
    :erpc.call(node, DurableServer.Supervisor, :ensure_started_child, args)
  catch
    :error, {:erpc, reason} -> {:error, {:erpc, reason}}
  end

  defp started({:ok, {pid, _meta}}), do: {:ok, pid}
  defp started({:error, reason}), do: {:error, reason}

  @doc """
  Stops an agent, syncing its state first so `spawn/2` brings it back as it was.

  The agent stays stopped until something spawns it again: a graceful stop
  would leave a permanent agent eligible for the supervisor's own restart.
  """
  @spec stop(AgentID.t()) :: :ok | {:error, term()}
  def stop(%AgentID{} = id) do
    DurableServer.Supervisor.terminate_child_permanent(@name, to_string(id))
  end

  @doc "Whether an agent is kept under `id`, running or stopped."
  @spec stored?(AgentID.t()) :: boolean()
  def stored?(%AgentID{} = id),
    do: match?({:ok, _info}, DurableServer.Supervisor.get_server_info(@name, to_string(id)))

  @doc "Stops an agent and deletes everything it had, permanently."
  @spec forget(AgentID.t()) :: :ok | {:error, term()}
  def forget(%AgentID{} = id),
    do: DurableServer.Supervisor.terminate_and_delete_child(@name, to_string(id))

  @doc """
  Forgets every running agent under `prefix`, and returns how many.

  Agents that are stored but not running are left where they are.
  """
  @spec forget_under(Prefix.t()) :: non_neg_integer()
  def forget_under(prefix) do
    members = list(prefix)
    Enum.each(members, &forget(&1.id))
    length(members)
  end

  @doc "The pid behind an ID, wherever in the cluster it is, or `nil`."
  @spec whereis(AgentID.t()) :: pid() | nil
  def whereis(%AgentID{} = id) do
    case DurableServer.Supervisor.lookup(@name, to_string(id)) do
      {pid, _meta} -> pid
      nil -> nil
    end
  end

  @doc "One agent as the fleet sees it, or `nil` when nothing holds that ID."
  @spec lookup(AgentID.t()) :: Member.t() | nil
  def lookup(%AgentID{} = id) do
    case DurableServer.Supervisor.lookup(@name, to_string(id)) do
      {pid, meta} -> Member.new(id, pid, meta)
      nil -> nil
    end
  end

  # -- the fleet -------------------------------------------------------------

  @doc """
  Every agent under `prefix`, across the cluster, sorted by ID.

  Reads each node's registry, so this is one call per node in the cluster.
  `watch/1` is the cheaper way to keep a view up to date.
  """
  @spec list(Prefix.t()) :: [Member.t()]
  def list(prefix \\ Prefix.all()) do
    for {key, {pid, meta}} <- DurableServer.Supervisor.global_members(@name),
        id = AgentID.parse!(key),
        Prefix.covers?(prefix, id) do
      Member.new(id, pid, meta.user_meta)
    end
    |> Enum.sort_by(&to_string(&1.id))
  end

  @doc """
  Sends this process a message whenever an agent under `prefix` starts, stops,
  or changes what it is doing.

  Messages arrive as `{:group, [%Group.Event{}], info}`, where each event's
  `key` is the agent ID's text. A state change re-registers metadata, so a
  `:registered` event carrying `previous_meta` is a change rather than a new
  agent.

      Wardrik.Fleet.watch(Wardrik.AgentID.Prefix.new!(org: "acme"))
      Wardrik.Fleet.watch()        # the whole cluster
  """
  @spec watch(Prefix.t()) :: :ok
  def watch(prefix \\ Prefix.all()) do
    Enum.each(Prefix.patterns(prefix), &(:ok = Group.monitor(@name, &1)))
  end

  @doc "Stops the messages `watch/1` started."
  @spec unwatch(Prefix.t()) :: :ok
  def unwatch(prefix \\ Prefix.all()) do
    Enum.each(Prefix.patterns(prefix), &(:ok = Group.demonitor(@name, &1)))
  end

  @doc """
  Interrupts every agent under `prefix`, and returns how many were told to stop.

  Each agent's turn is interrupted and its queue discarded; the agents stay up.
  Use `stop/1` or `forget/1` to be rid of one.
  """
  @spec kill(Prefix.t()) :: non_neg_integer()
  def kill(prefix \\ Prefix.all()) do
    members = list(prefix)
    Enum.each(members, &Agent.interrupt(&1.pid))
    length(members)
  end
end
