defmodule Tars.Fleet do
  @moduledoc """
  Every agent in the cluster: what is running, what it is doing, and how to
  stop it.

  | Function | Answers |
  | --- | --- |
  | `list/1` | which agents are running, and what each is doing |
  | `watch/1` | the same, as messages, whenever it changes |
  | `kill/1` | stop everything under a prefix |
  | `whereis/1` | the pid behind a key, on whatever node holds it |

  ## Keys

  An agent's key is its address across the cluster and its topic on the event
  bus. It reads `org/user/name`, so the three ways a fleet is sliced are
  prefixes of one string:

      Tars.Fleet.list()             # everything
      Tars.Fleet.list("acme/")      # one tenant
      Tars.Fleet.list("acme/jon/")  # one person's agents

  The org and user are the same `:user` and `:org` the agent's scope carries,
  written down through `Tars.Fleet.Segment`, so identity is given once:

      Tars.Fleet.spawn("researcher", user: current_user, org: current_org)

  An absent org or user becomes `#{inspect("_")}`, so a deployment with no
  identity still has keys:

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
  alias Tars.Fleet.Member
  alias Tars.Fleet.Segment

  @name __MODULE__
  @prefix "tars/agents/"
  @anonymous "_"

  @doc false
  @spec prefix() :: String.t()
  def prefix, do: @prefix

  @doc "Whether the fleet is running on this node."
  @spec running?() :: boolean()
  def running?, do: is_pid(Process.whereis(@name))

  # -- keys ------------------------------------------------------------------

  @doc """
  The key an agent is addressed by. A name containing a `/` is already a key
  and is passed through.

  Options are the scope's own `:org` and `:user`, written down through
  `Tars.Fleet.Segment`.
  """
  @spec key(String.t(), keyword()) :: String.t()
  def key(name, opts \\ []) when is_binary(name) do
    if String.contains?(name, "/") do
      name
    else
      Enum.map_join([opts[:org], opts[:user], name], "/", &segment/1)
    end
  end

  defp segment(nil), do: @anonymous
  defp segment(""), do: @anonymous

  defp segment(value) do
    case Segment.to_segment(value) do
      "" ->
        @anonymous

      segment ->
        if String.contains?(segment, "/") do
          raise ArgumentError,
                "a fleet key segment may not contain \"/\", got #{inspect(segment)} " <>
                  "from #{inspect(value)}"
        end

        segment
    end
  end

  @doc """
  The org, user and name a key is made of.

  A key with fewer than three segments reports `#{inspect(@anonymous)}` for what
  it does not carry.
  """
  @spec parse(String.t()) :: {String.t(), String.t(), String.t()}
  def parse(key) when is_binary(key) do
    case String.split(key, "/") do
      [org, user, name] -> {org, user, name}
      [user, name] -> {@anonymous, user, name}
      [name] -> {@anonymous, @anonymous, name}
      [org, user | rest] -> {org, user, Enum.join(rest, "/")}
    end
  end

  # -- lifecycle -------------------------------------------------------------

  @doc """
  Starts an agent in the fleet, or returns the one already running under its key.

  `name` is either a bare name or a full key. Options are everything
  `Tars.Agent.initial_state/2` takes; `:org` and `:user` also build the key.

      {:ok, pid} = Tars.Fleet.spawn("researcher", config: config, org: "acme")

  The agent is placed on whichever node has capacity, so the pid may be remote.
  """
  @spec spawn(String.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def spawn(name, opts \\ []) when is_binary(name) do
    key = key(name, opts)
    child = {Agent, key: key, initial_state: Agent.initial_state(opts, key)}

    case DurableServer.Supervisor.ensure_started_child(@name, child) do
      {:ok, {pid, _meta}} -> {:ok, pid}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Stops an agent, syncing its state first so `spawn/2` brings it back as it was."
  @spec stop(String.t()) :: :ok | {:error, term()}
  def stop(key) when is_binary(key) do
    DurableServer.Supervisor.terminate_child(@name, key)
  end

  @doc "Stops an agent and deletes everything it had, permanently."
  @spec forget(String.t()) :: :ok | {:error, term()}
  def forget(key) when is_binary(key) do
    DurableServer.Supervisor.terminate_and_delete_child(@name, key)
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
      {pid, meta} -> Member.new(key, pid, meta || %{})
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
    @name
    |> DurableServer.Supervisor.global_members()
    |> Enum.filter(&agent_under?(&1, prefix))
    |> Enum.map(fn {key, {pid, meta}} -> Member.new(key, pid, user_meta(meta)) end)
    |> Enum.sort_by(& &1.key)
  end

  defp agent_under?({key, {_pid, meta}}, prefix) do
    String.starts_with?(key, prefix) and module(meta) == Agent
  end

  defp module(%DurableServer.GroupMeta{module: module}), do: module
  defp module(_meta), do: nil

  defp user_meta(%DurableServer.GroupMeta{user_meta: meta}) when is_map(meta), do: meta
  defp user_meta(_meta), do: %{}

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
    prefix
    |> list()
    |> Enum.map(&Agent.interrupt(&1.pid))
    |> length()
  end
end
