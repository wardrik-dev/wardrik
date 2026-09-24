defmodule Tars.Fleet do
  @moduledoc """
  Every agent in the cluster: what is running, what it is doing, and how to
  stop it.

  | Function | Answers |
  | --- | --- |
  | `put/1` | start an agent from its `Tars.Agent.Spec`, or bring a running one to it |
  | `list/1` | which agents are running, and what each is doing |
  | `watch/1` | the same, as messages, whenever it changes |
  | `kill/1` | interrupt everything under a prefix |
  | `forget/1`, `forget_under/1` | remove an agent, or every agent under a prefix, and its store |
  | `move/2` | restart an agent on another node, as it was |
  | `whereis/1` | the pid behind a key, on whatever node holds it |

  ## Keys

  An agent's key is its address across the cluster and its topic on the event
  bus. It reads `org/user/name`, so the three ways a fleet is sliced are
  prefixes of one string:

      Tars.Fleet.list()             # everything
      Tars.Fleet.list("acme/")      # one tenant
      Tars.Fleet.list("acme/jon/")  # one person's agents

  `key/2` builds one from a name and the host's own org and user values,
  written down through `Tars.Fleet.Segment`. The agent's scope reads `:org`
  and `:user` back out of the key, so identity is given once:

      key = Tars.Fleet.key("researcher", user: current_user, org: current_org)
      Tars.Fleet.spawn(key, config: config)

  An absent org or user is `#{inspect("_")}` in the key and `nil` on the scope:

      Tars.Fleet.key("researcher")                           #=> "_/_/researcher"
      Tars.Fleet.key("researcher", org: "acme", user: "jon") #=> "acme/jon/researcher"

  ## Listing

  Agents publish what they are doing as registry metadata when it changes, and
  the registry replicates between nodes, so `list/1` is a table read that sends
  no messages and `watch/1` needs no polling.

  ## Durability

  Agents are `DurableServer` processes: one per key across the cluster under a
  lock, state written to the store on every change that matters, and restarted
  on another node when theirs is lost. See `Tars.Agent.State` for what survives
  a restart and what does not.
  """

  alias Tars.Agent
  alias Tars.Agent.Spec
  alias Tars.Fleet.Member
  alias Tars.Fleet.Segment
  alias Tars.Schedule

  @name __MODULE__
  @prefix "tars/agents/"
  @anonymous "_"

  @doc false
  @spec prefix() :: String.t()
  def prefix, do: @prefix

  # -- keys ------------------------------------------------------------------

  @doc """
  The key an agent is addressed by, from its name and the `:org` and `:user`
  it works for. Each is written down through `Tars.Fleet.Segment`, and none
  may contain `/`.
  """
  @spec key(String.t(), keyword()) :: String.t()
  def key(name, opts \\ []) when is_binary(name) do
    Enum.map_join([opts[:org], opts[:user], name], "/", &segment/1)
  end

  defp segment(nil), do: @anonymous

  defp segment(value) do
    case Segment.to_segment(value) do
      "" ->
        @anonymous

      segment when is_binary(segment) ->
        if String.contains?(segment, "/") do
          raise ArgumentError,
                "a fleet key segment may not contain \"/\", got #{inspect(segment)} " <>
                  "from #{inspect(value)}"
        end

        segment
    end
  end

  @doc """
  The org, user and name a key is made of, with `nil` for an org or user the
  key does not carry. Raises on anything `key/2` would not have built.
  """
  @spec parse(String.t()) :: {String.t() | nil, String.t() | nil, String.t()}
  def parse(key) when is_binary(key) do
    case String.split(key, "/") do
      [org, user, name] -> {identity(org), identity(user), name}
      _other -> raise ArgumentError, "a fleet key is org/user/name, got #{inspect(key)}"
    end
  end

  defp identity(@anonymous), do: nil
  defp identity(segment), do: segment

  # -- lifecycle -------------------------------------------------------------

  @doc """
  Starts an agent in the fleet, or returns the one already running under its key.

  Options are everything `Tars.Agent.initial_state/2` takes, and `:node`, the
  node to start it on. Without one the agent is placed on whichever node has
  capacity, so the pid may be remote either way.

      {:ok, pid} = Tars.Fleet.spawn(Tars.Fleet.key("researcher", org: "acme"), config: config)
      {:ok, pid} = Tars.Fleet.spawn(key, config: config, node: :"tars_b@host")
  """
  @spec spawn(String.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def spawn(key, opts \\ []) when is_binary(key) do
    {node, opts} = Keyword.pop(opts, :node)

    child(key, opts) |> start(node) |> started()
  end

  @doc """
  Makes the fleet match `spec`: starts the agent it describes where none runs
  under its key, and gives the one that does the spec's config and seams with
  `Tars.Agent.configure/2`. The agent keeps its conversation either way.

      {:ok, pid} = Tars.Fleet.put(Tars.Agent.Spec.new(name: "triage", org: "acme"))
  """
  @spec put(Spec.t()) :: {:ok, pid()} | {:error, term()}
  def put(%Spec{} = spec) do
    options = Spec.options(spec)

    with {:ok, pid} <- spawn(Spec.key(spec), options),
         :ok <- Agent.configure(pid, options),
         :ok <- Schedule.sync(Spec.key(spec), spec.schedules) do
      {:ok, pid}
    end
  end

  @doc """
  Stops an agent and starts it again on `node`, with the state it had.

      {:ok, pid} = Tars.Fleet.move("acme/jon/researcher", :"tars_b@host")
  """
  @spec move(String.t(), node()) :: {:ok, pid()} | {:error, term()}
  def move(key, node) when is_binary(key) and is_atom(node) do
    @name
    |> DurableServer.Supervisor.rehome_child(child(key, []), target_node: node)
    |> started()
  end

  defp child(key, opts), do: {Agent, key: key, initial_state: Agent.initial_state(opts, key)}

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
  @spec stop(String.t()) :: :ok | {:error, term()}
  def stop(key) when is_binary(key) do
    DurableServer.Supervisor.terminate_child_permanent(@name, key)
  end

  @doc "Stops an agent and deletes everything it had, its schedules included, permanently."
  @spec forget(String.t()) :: :ok | {:error, term()}
  def forget(key) when is_binary(key) do
    with :ok <- Schedule.sync(key, []) do
      DurableServer.Supervisor.terminate_and_delete_child(@name, key)
    end
  end

  @doc """
  Forgets every running agent under `prefix`, and returns how many.

  Agents that are stored but not running are left where they are.
  """
  @spec forget_under(String.t()) :: non_neg_integer()
  def forget_under(prefix) when is_binary(prefix) do
    members = list(prefix)
    Enum.each(members, &forget(&1.key))
    length(members)
  end

  @doc "The pid behind a key, wherever in the cluster it is, or `nil`."
  @spec whereis(String.t()) :: pid() | nil
  def whereis(key) when is_binary(key) do
    case DurableServer.Supervisor.lookup(@name, key) do
      {pid, _meta} -> pid
      nil -> nil
    end
  end

  @doc "One agent as the fleet sees it, or `nil` when nothing holds that key."
  @spec lookup(String.t()) :: Member.t() | nil
  def lookup(key) when is_binary(key) do
    case DurableServer.Supervisor.lookup(@name, key) do
      {pid, meta} -> Member.new(key, pid, meta)
      nil -> nil
    end
  end

  # -- the fleet -------------------------------------------------------------

  @doc """
  Every agent whose key starts with `prefix`, across the cluster, sorted by key.

  Reads each node's registry, so this is one call per node in the cluster.
  `watch/1` is the cheaper way to keep a view up to date.
  """
  @spec list(String.t()) :: [Member.t()]
  def list(prefix \\ "") when is_binary(prefix) do
    for {key, {pid, meta}} <- DurableServer.Supervisor.global_members(@name),
        String.starts_with?(key, prefix) do
      Member.new(key, pid, meta.user_meta)
    end
    |> Enum.sort_by(& &1.key)
  end

  @doc """
  Sends this process a message whenever an agent under `prefix` starts, stops,
  or changes what it is doing.

  Messages arrive as `{:group, [%Group.Event{}], info}`. A state change
  re-registers metadata, so a `:registered` event carrying `previous_meta` is a
  change rather than a new agent.

      Tars.Fleet.watch("acme/")
      Tars.Fleet.watch()        # the whole cluster
  """
  @spec watch(String.t()) :: :ok
  def watch(prefix \\ "") when is_binary(prefix), do: Group.monitor(@name, pattern(prefix))

  @doc "Stops the messages `watch/1` started."
  @spec unwatch(String.t()) :: :ok
  def unwatch(prefix \\ "") when is_binary(prefix), do: Group.demonitor(@name, pattern(prefix))

  defp pattern(""), do: :all
  defp pattern(prefix), do: prefix

  @doc """
  Interrupts every agent under `prefix`, and returns how many were told to stop.

  Each agent's turn is interrupted and its queue discarded; the agents stay up.
  Use `stop/1` or `forget/1` to be rid of one.
  """
  @spec kill(String.t()) :: non_neg_integer()
  def kill(prefix \\ "") when is_binary(prefix) do
    members = list(prefix)
    Enum.each(members, &Agent.interrupt(&1.pid))
    length(members)
  end
end
