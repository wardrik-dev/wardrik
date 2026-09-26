defmodule WardrikDaemon.Cluster do
  @moduledoc """
  Joins this daemon to others, so the fleet, its store and the schedules span
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

  The store counts a quorum over the cluster's size: the number of `nodes`, or
  `size` with `dns`. More than half of them must be connected for the fleet to
  start or move an agent, so three nodes carry on with one lost, and two stop
  when either is. A node starting waits until enough of the others are up,
  saying so in its log and in `wardrik status`, and starts its agents once they
  are.

  A release reads `cluster` as it boots, before anything starts; see
  `config/runtime.exs`. This supervisor runs a `WardrikDaemon.Cluster.Topology`
  for the way the cluster is found, which connects to the nodes it finds, and
  `WardrikDaemon.Cluster.Quorum` beside it holds the fleet back until a quorum of
  them is connected. Core starts both before the fleet, as its `:cluster`:

      config :wardrik, :cluster, [WardrikDaemon.Cluster, WardrikDaemon.Cluster.Quorum]

  Nodes on one machine share a config directory. Only one of them listens for
  SSH, and for OAuth's callback, at a time; see `WardrikDaemon.SSH`.
  """

  use Supervisor

  alias WardrikDaemon.Cluster.Strategy
  alias WardrikDaemon.Cluster.Topology

  @local_host "localhost"

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    case topologies() do
      [] ->
        :ignore

      topologies ->
        Supervisor.init(Enum.map(topologies, &Topology.child_spec/1), strategy: :one_for_one)
    end
  end

  @doc "Whether `config.yaml` describes a cluster."
  @spec configured?() :: boolean()
  def configured?, do: topologies() != []

  @doc "The topologies that find the cluster's nodes."
  @spec topologies() :: [Topology.t()]
  def topologies, do: Keyword.get(settings(), :topologies, [])

  @doc "How many nodes the store counts a quorum over, and 1 where there is no cluster."
  @spec size() :: pos_integer()
  def size, do: Keyword.get(settings(), :size, 1)

  @doc "The nodes `cluster.nodes` names, or none where the cluster is found by DNS."
  @spec named() :: [node()]
  def named, do: Keyword.get(settings(), :nodes, [])

  @doc "How many of the cluster's nodes must be connected, this one among them."
  @spec quorum(pos_integer()) :: pos_integer()
  def quorum(size \\ size()), do: div(size, 2) + 1

  @doc """
  The cluster's nodes this one is connected to, itself among them: those
  `cluster.nodes` names, or those DNS resolves to now.
  """
  @spec members() :: [node()]
  def members do
    connected = MapSet.new([node() | Node.list()])

    topologies()
    |> Enum.flat_map(&Strategy.nodes(&1.strategy))
    |> Enum.uniq()
    |> Enum.filter(&MapSet.member?(connected, &1))
    |> Enum.sort()
  end

  @doc """
  Why this node may not be one of the cluster's at all, or `nil` where it
  may: `cluster.nodes` does not name it.
  """
  @spec refusal() :: String.t() | nil
  def refusal do
    if named() != [] and node() not in named() do
      "#{display(node())} is not one of cluster.nodes: " <>
        Enum.map_join(named(), ", ", &display/1) <> "; start one of them with --node"
    end
  end

  @doc """
  Why this node cannot start its agents yet, or `nil` where it can: too few of
  the cluster's nodes are connected for a quorum.
  """
  @spec waiting() :: String.t() | nil
  def waiting do
    if configured?() and is_nil(refusal()), do: short_of_quorum(members())
  end

  defp short_of_quorum(members) do
    case quorum() - length(members) do
      needed when needed > 0 ->
        "#{display(node())} is waiting for #{needed} more #{plural(needed, "node")} " <>
          "to reach a quorum of #{quorum()} of #{size()}" <> connected_to(members -- [node()])

      _enough ->
        nil
    end
  end

  defp connected_to([]), do: ""
  defp connected_to(nodes), do: "; connected to " <> Enum.map_join(nodes, ", ", &display/1)

  defp plural(1, word), do: word
  defp plural(_count, word), do: word <> "s"

  @doc """
  The node a name in `cluster.nodes` or `--node` stands for: `a` is
  `wardrik_a@localhost`, one of several on this machine, and a full name is
  itself.
  """
  @spec node_name(String.t()) :: node()
  def node_name(name) when is_binary(name) do
    if String.contains?(name, "@"),
      # reach:disable-next-line unsafe_atom_creation -- a node name from config.yaml or --node
      do: String.to_atom(name),
      # reach:disable-next-line unsafe_atom_creation -- a node name from config.yaml or --node
      else: String.to_atom("wardrik_#{name}@#{@local_host}")
  end

  @doc "How `wardrik` shows a node: by its short name where it is one of several on this machine."
  @spec display(node()) :: String.t()
  def display(node) when is_atom(node) do
    case String.split(Atom.to_string(node), "@") do
      ["wardrik_" <> name, @local_host] -> name
      _other -> Atom.to_string(node)
    end
  end

  defp settings, do: Application.get_env(:wardrik, __MODULE__, [])
end
