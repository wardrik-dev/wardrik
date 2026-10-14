defmodule WardrikDaemon.Cluster do
  @moduledoc """
  Joins this daemon to others, so the fleet, its store and the triggers span
  them all, and an agent whose node is lost carries on on another.

  `config.yaml` says which nodes the cluster has, in one of two ways:

      # nodes on this machine, by name
      cluster:
        nodes: [a, b, c]

      # one node on each of several machines
      cluster:
        nodes: [wardrik@box1, wardrik@box2, wardrik@box3]

      # every node a DNS name resolves to, however many there are now
      cluster:
        dns: wardrik.internal
        size: 3

  Each node is started as one of them, with `wardrik start --node NAME` or
  `WARDRIK_NODE`, and connects to the rest.

    * A name without `@` is one of several nodes on this machine: node `a` runs
      as `wardrik_a@localhost`, with a store and logs of its own under the
      install's directories and the install's cookie. They reach one another
      over loopback.
    * A full name is the one node on its machine. The nodes reach one another
      over a private network, so each listens on its address there, with
      `WARDRIK_DIST_INTERFACE` and `WARDRIK_DIST_EXPOSED=1`, and shares the cookie
      in `RELEASE_COOKIE`. See SECURITY.md.
    * `dns` finds a node named `wardrik@ADDRESS` at each address the name
      resolves to, so each node runs with `WARDRIK_NODE` set to `wardrik@` and its
      own address, on a private network as above.

  ## Quorum

  A store kept on the nodes themselves, as it is without `storage` in
  `config.yaml`, counts a quorum over the cluster's size: the number of
  `nodes`, or `size` with `dns`. More than half of them must be connected for
  the fleet to start or move an agent, so three nodes carry on with one lost,
  and two stop when either is. A node starting waits until enough of the
  others are up, saying so in its log and in `wardrik status`, and starts its
  agents once they are.

  A store kept elsewhere, in Postgres or S3, needs no quorum: each node starts
  on its own, and the fleet carries on while any node is up. The store says
  which; see `WardrikStore.quorum/2`.

  A release reads `cluster` as it boots, before anything starts; see
  `config/runtime.exs`, and hands it to this supervisor, which runs a
  `WardrikDaemon.Cluster.Topology` for the way the cluster is found, which
  connects to the nodes it finds, and to `WardrikDaemon.Cluster.Quorum`
  beside it, which holds the rest back until a quorum of them, as the store
  counts it, is connected. Every function here is handed those settings:

      [{WardrikDaemon.Cluster, cluster}, {WardrikDaemon.Cluster.Quorum, store: store, cluster: cluster}]

  Nodes on one machine share a config directory. Only one of them listens for
  SSH, and for OAuth's callback, at a time; see `WardrikDaemon.SSH`.
  """

  use Supervisor

  alias WardrikConsole.Nodes
  alias WardrikDaemon.Cluster.Strategy
  alias WardrikDaemon.Cluster.Topology

  @typedoc "What `config.yaml`'s `cluster` reads into: its `:topologies`, `:size` and `:nodes`."
  @type settings() :: keyword()

  @doc false
  @spec child_spec(settings()) :: Supervisor.child_spec()
  def child_spec(cluster),
    do: %{id: __MODULE__, start: {__MODULE__, :start_link, [cluster]}, type: :supervisor}

  @doc "Starts the topologies `cluster` names, or nothing where it names none."
  @spec start_link(settings()) :: Supervisor.on_start()
  def start_link(cluster), do: Supervisor.start_link(__MODULE__, cluster, name: __MODULE__)

  @impl true
  def init(cluster) do
    case topologies(cluster) do
      [] ->
        :ignore

      topologies ->
        Supervisor.init(Enum.map(topologies, &Topology.child_spec/1), strategy: :one_for_one)
    end
  end

  @doc "Whether `config.yaml` describes a cluster."
  @spec configured?(settings()) :: boolean()
  def configured?(cluster), do: topologies(cluster) != []

  @doc "The topologies that find the cluster's nodes."
  @spec topologies(settings()) :: [Topology.t()]
  def topologies(cluster), do: Keyword.get(cluster, :topologies, [])

  @doc "How many nodes the store counts a quorum over, and 1 where there is no cluster."
  @spec size(settings()) :: pos_integer()
  def size(cluster), do: Keyword.get(cluster, :size, 1)

  @doc "The nodes `cluster.nodes` names, or none where the cluster is found by DNS."
  @spec named(settings()) :: [node()]
  def named(cluster), do: Keyword.get(cluster, :nodes, [])

  @doc "How many of the cluster's nodes must be connected, this one among them, as `store` counts them."
  @spec quorum(settings(), WardrikStore.t()) :: pos_integer()
  def quorum(cluster, store), do: WardrikStore.quorum(store, size(cluster))

  @doc """
  The cluster's nodes this one is connected to, itself among them: those
  `cluster.nodes` names, or those DNS resolves to now.
  """
  @spec members(settings()) :: [node()]
  def members(cluster) do
    connected = MapSet.new([node() | Node.list()])

    cluster
    |> topologies()
    |> Enum.flat_map(&Strategy.nodes(&1.strategy))
    |> Enum.uniq()
    |> Enum.filter(&MapSet.member?(connected, &1))
    |> Enum.sort()
  end

  @doc """
  Why this node may not be one of the cluster's at all, or `nil` where it
  may: `cluster.nodes` does not name it.
  """
  @spec refusal(settings()) :: String.t() | nil
  def refusal(cluster) do
    named = named(cluster)

    if named != [] and node() not in named do
      "#{Nodes.display(node())} is not one of cluster.nodes: " <>
        Enum.map_join(named, ", ", &Nodes.display/1) <> "; start one of them with --node"
    end
  end

  @doc """
  Why this node cannot start its agents yet, or `nil` where it can: too few of
  the cluster's nodes are connected for a quorum, as `store` counts it.
  """
  @spec waiting(settings(), WardrikStore.t()) :: String.t() | nil
  def waiting(cluster, store) do
    if configured?(cluster) and is_nil(refusal(cluster)),
      do: short_of_quorum(cluster, quorum(cluster, store), members(cluster))
  end

  defp short_of_quorum(cluster, quorum, members) do
    case quorum - length(members) do
      needed when needed > 0 ->
        "#{Nodes.display(node())} is waiting for #{needed} more #{plural(needed, "node")} " <>
          "to reach a quorum of #{quorum} of #{size(cluster)}" <>
          connected_to(members -- [node()])

      _enough ->
        nil
    end
  end

  defp connected_to([]), do: ""
  defp connected_to(nodes), do: "; connected to " <> Enum.map_join(nodes, ", ", &Nodes.display/1)

  defp plural(1, word), do: word
  defp plural(_count, word), do: word <> "s"
end
