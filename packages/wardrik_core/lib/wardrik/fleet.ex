defmodule Wardrik.Fleet do
  @moduledoc """
  Every agent in the cluster: what is running, what it is doing, and how to
  stop it.

  | Function | Answers |
  | --- | --- |
  | `put/1` | start an agent from its `Wardrik.Agent.Spec`, or bring a running one to it |
  | `list/2` | every agent, awake, asleep or defined, and what each is doing |
  | `held/1` | every agent awake or asleep, without those only defined |
  | `watch/1` | what is awake, as messages, whenever it changes |
  | `forget/1`, `forget_under/1` | remove an agent, or every agent under a prefix, and its store |
  | `move/2` | restart an agent on another node, as it was |
  | `whereis/2` | the pid behind an ID, on whatever node holds it, waking it where it sleeps or starting it from its definition |
  | `stored?/1` | whether the store holds an agent, running or stopped |

  An agent is addressed by its `Wardrik.AgentID`, and the fleet is sliced by
  `Wardrik.AgentID.Prefix`:

      Wardrik.Fleet.list(Wardrik.AgentID.Prefix.all(), host: host)            # everything
      Wardrik.Fleet.list(Wardrik.AgentID.Prefix.new!(org: "acme"), host: host)  # one tenant

  ## Listing

  Agents publish what they are doing as registry metadata when it changes, and
  the registry replicates between nodes, so `watch/1` needs no polling. An
  agent that has gone to sleep, as `Wardrik.Agent` describes, is in no
  registry: `list/2` reads it from the store, as it wrote itself down. One
  the host defines that has not started, or whose state this release cannot
  read, is listed asleep and idle, from the host's
  `c:Wardrik.Definition.defined/2`.

  ## Waking

  An agent asleep is started again from the store by `whereis/2`, which every
  command reaching an agent by its ID goes through, and by `spawn/2`. As it
  wakes, it asks the host it is handed for its spec, as `Wardrik.Agent`
  describes, so a host that changes a definition need wake no agent to
  apply it, and changes only the agents awake. A host that keeps no
  definitions leaves every agent to wake as it slept, and `put/1` is how a
  sleeping agent is given a new definition.

  An agent the store does not hold, but the host defines, starts from its
  definition the same way. So does one whose state this release cannot
  read, as after a change to what an agent writes down: a warning names it,
  and it starts with an empty history, its log kept and any turn it parked
  on a person lost. One with neither is not found.

  The host an agent is handed as it starts is the one `Wardrik.Core` was
  started with, which the fleet's supervisor hands it. The host whose
  definitions `whereis/2`, `lookup/2` and `list/2` read is the caller's, as
  their `:host`.

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
  Starts an agent in the fleet, or returns the one already running under its
  ID, waking it where it sleeps.

  Options are everything `Wardrik.Agent.initial_state/2` takes, for an agent
  the store does not hold, and `:node`, the node to start it on. Without one
  the agent is placed on whichever node has capacity, or wakes where it
  slept, so the pid may be remote either way. One the host defines takes its
  definition as it starts, as `Wardrik.Agent` describes.

      {:ok, pid} = Wardrik.Fleet.spawn(Wardrik.AgentID.new!("researcher", org: "acme"), config: config)
      {:ok, pid} = Wardrik.Fleet.spawn(id, config: config, node: :"wardrik_b@host")
  """
  @spec spawn(AgentID.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def spawn(%AgentID{} = id, opts \\ []) do
    {node, opts} = Keyword.pop(opts, :node)
    id |> child(opts) |> start(node) |> started()
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

    with {:ok, pid} <- spec.id |> child(options) |> start(nil) |> started(),
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
  Stops an agent, syncing its state first, so it sleeps as it was until
  something wakes it.

  The stop is permanent: a graceful one would leave the agent eligible for
  the supervisor's own restart.
  """
  @spec stop(AgentID.t()) :: :ok | {:error, term()}
  def stop(%AgentID{} = id) do
    DurableServer.Supervisor.terminate_child_permanent(@name, to_string(id))
  end

  @doc "Whether an agent is kept under `id`, running or stopped."
  @spec stored?(AgentID.t()) :: boolean()
  def stored?(%AgentID{} = id), do: match?({:ok, _info}, info(id))

  @doc """
  What a stopped agent wrote down as it stopped, read without starting it.
  One running writes itself down as it goes, so what this reads of it may
  already be behind.
  """
  @spec written(AgentID.t()) :: {:ok, Wardrik.Agent.State.Stored.t()} | {:error, :not_found}
  def written(%AgentID{} = id) do
    with {:ok, info} <- info(id), do: {:ok, info.user_state}
  end

  # A forgotten agent can leave a tombstone, which is no agent.
  defp info(id) do
    case DurableServer.Supervisor.get_server_info(@name, to_string(id)) do
      {:ok, %{status: :deleting}} -> {:error, :not_found}
      {:ok, info} -> {:ok, info}
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  @doc "Stops an agent and deletes everything it had, permanently."
  @spec forget(AgentID.t()) :: :ok | {:error, term()}
  def forget(%AgentID{} = id),
    do: DurableServer.Supervisor.terminate_and_delete_child(@name, to_string(id))

  @doc "Forgets every agent under `prefix`, awake or asleep, and returns how many."
  @spec forget_under(Prefix.t()) :: non_neg_integer()
  def forget_under(prefix) do
    members = held(prefix)
    Enum.each(members, &forget(&1.id))
    length(members)
  end

  @doc """
  The pid behind an ID, wherever in the cluster it is, or `nil` where neither
  the store nor the host's definitions hold an agent under it.

  An agent asleep is started from the store first, as it was, and one the
  store does not hold from its definition. Callers racing to wake one agent,
  on any node, start one process between them.

    * `:host` - the `Wardrik.Host` whose definitions an agent the store does
      not hold is started from. A caller that may reach such an agent passes
      it
    * `:wake` - `false` answers `nil` for an agent asleep, for a caller with
      nothing to ask of it

      pid = Wardrik.Fleet.whereis(id, host: host)
  """
  @spec whereis(AgentID.t(), host: Wardrik.Host.t(), wake: boolean()) :: pid() | nil
  def whereis(%AgentID{} = id, opts) do
    case DurableServer.Supervisor.lookup(@name, to_string(id)) do
      {pid, _meta} -> pid
      nil -> if Keyword.get(opts, :wake, true), do: wake(id, opts)
    end
  end

  # The checks spare a start for an ID nothing holds; `:wake_only` keeps one
  # forgotten since from coming back empty.
  defp wake(id, opts) do
    with true <- stored?(id) or defined?(id, opts),
         {:ok, {pid, meta}} when not is_map_key(meta, :gone) <-
           id |> child(wake_only: true) |> start(nil) do
      pid
    else
      _gone -> nil
    end
  end

  @doc """
  One agent as the fleet sees it, awake or asleep, or `nil` when neither the
  fleet nor the definitions of the `:host` given hold that ID.
  """
  @spec lookup(AgentID.t(), host: Wardrik.Host.t()) :: Member.t() | nil
  def lookup(%AgentID{} = id, opts) do
    case DurableServer.Supervisor.lookup(@name, to_string(id)) do
      {pid, meta} -> Member.new(id, pid, meta)
      nil -> asleep(id, opts)
    end
  end

  defp asleep(id, opts) do
    case written(id) do
      {:ok, dumped} -> Member.asleep(id, dumped)
      {:error, :not_found} -> if defined?(id, opts), do: Member.asleep(id)
    end
  end

  defp defined?(id, opts),
    do: match?({:ok, _spec}, Wardrik.Definition.current(definitions(opts), id))

  defp definitions(opts), do: opts |> Keyword.fetch!(:host) |> Wardrik.Host.definitions()

  # -- the fleet -------------------------------------------------------------

  @doc """
  Every agent under `prefix`, across the cluster, awake or asleep, sorted by
  ID: those `held/1` answers, and those the definitions of the `:host` given
  hold that have not started.

      Wardrik.Fleet.list(Wardrik.AgentID.Prefix.new!(org: "acme"), host: host)
  """
  @spec list(Prefix.t(), host: Wardrik.Host.t()) :: [Member.t()]
  def list(prefix, opts) do
    held = held(prefix)
    started = MapSet.new(held, & &1.id)

    defined =
      for id <- Wardrik.Definition.defined(definitions(opts), prefix),
          not MapSet.member?(started, id),
          do: Member.asleep(id)

    Enum.sort_by(held ++ defined, &to_string(&1.id))
  end

  @doc """
  Every agent under `prefix` the fleet holds, across the cluster, awake or
  asleep, sorted by ID.

  Reads each node's registry for the agents awake, and the store for those
  asleep, so it reads every agent the store holds. `watch/1` is the cheaper
  way to keep a view of the agents awake up to date.
  """
  @spec held(Prefix.t()) :: [Member.t()]
  def held(prefix) do
    awake =
      for {key, {pid, meta}} <- DurableServer.Supervisor.global_members(@name),
          id <- under(prefix, key),
          into: %{},
          do: {key, Member.new(id, pid, meta.user_meta)}

    asleep =
      for info <- DurableServer.Supervisor.stream_all_server_info(@name),
          not info.running,
          info.status != :deleting,
          not Map.has_key?(awake, info.key),
          id <- under(prefix, info.key),
          do: Member.asleep(id, info.user_state)

    Enum.sort_by(Map.values(awake) ++ asleep, &to_string(&1.id))
  end

  defp under(prefix, key) do
    with {:ok, id} <- AgentID.parse(key), true <- Prefix.covers?(prefix, id) do
      [id]
    else
      _elsewhere -> []
    end
  end

  @doc """
  Sends this process a message whenever an agent under `prefix` starts, stops,
  or changes what it is doing.

  Messages arrive as `{:group, [%Group.Event{}], info}`, where each event's
  `key` is the agent ID's text. A state change re-registers metadata, so a
  `:registered` event carrying `previous_meta` is a change rather than a new
  agent. Agents are matched by the start of their ID's text, so watching an
  org's own agents, `acme/`, hears of its users' too: pass each event's key
  through `Wardrik.AgentID.Prefix.covers?/2` where that matters.

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

  @doc "The nodes agents run on: this one, and every one connected to it."
  @spec nodes() :: [node()]
  def nodes, do: [Node.self() | Node.list()]
end
