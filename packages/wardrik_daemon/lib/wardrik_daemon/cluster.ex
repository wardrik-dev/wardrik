defmodule WardrikDaemon.Cluster do
  @moduledoc """
  Runs several daemons as one cluster. Any node answers for all of them, and when a node is lost
  its agents carry on on another.

  `config.yaml` names the nodes in one of three ways:

      # nodes on this machine
      cluster:
        nodes: [a, b, c]

      # one node on each machine
      cluster:
        nodes: [wardrik@box1, wardrik@box2, wardrik@box3]

      # a node at each address a DNS name resolves to
      cluster:
        dns: wardrik.internal
        size: 3

  `WARDRIK_NODE` says which node this one is, as `wardrik start --node a` sets it.

    * A short name is one of several nodes on this machine. Node `a` runs as
      `wardrik_a@localhost`, with a store and logs of its own under `nodes/a/`. The nodes share
      the config, the cookie and the vault's key. They share the HTTP API's port: the first to
      start listens, and another takes the port over when that one stops.
    * A full name is the one node on its machine. Nodes reach each other on a private network:
      set `WARDRIK_DIST_INTERFACE` to this machine's address on it, `WARDRIK_DIST_EXPOSED=1`, and
      the same `RELEASE_COOKIE` on every node.
    * `dns` finds a node named `wardrik@ADDRESS` at each A and AAAA record, so each node runs with
      `WARDRIK_NODE=wardrik@` and its own address.

  `libcluster` connects the nodes, and tries again every 5 seconds, so nodes start in any order.

  ## Quorum

  With the store on the nodes' disks, a write needs more than half of the cluster's nodes: the
  number of `nodes`, or `size`. So three nodes carry on with one lost, and two stop when either
  is. A node starting waits up to an hour for a quorum, then stops. With the store in Postgres,
  nodes don't wait for each other.

  A node `nodes` doesn't name refuses to start.
  """

  @enforce_keys [:size]
  defstruct [:dns, :size, nodes: []]

  @type t() :: %__MODULE__{nodes: [node()], dns: String.t() | nil, size: pos_integer()}

  @poll :timer.seconds(5)
  @quorum_wait :timer.hours(1)
  @short ~r/^[A-Za-z0-9_-]+$/
  @full ~r/^[A-Za-z0-9_-]+@[A-Za-z0-9_.:-]+$/

  @doc """
  Returns the cluster `config.yaml`'s `cluster` names, or `nil` if it has none.

      {:ok, %WardrikDaemon.Cluster{size: 2}} = WardrikDaemon.Cluster.new(nodes: ["a", "b"])
  """
  @spec new(keyword() | nil) :: {:ok, t() | nil} | {:error, String.t()}
  def new(nil), do: {:ok, nil}

  def new(opts) do
    case {opts[:nodes], opts[:dns], opts[:size]} do
      {[_ | _] = nodes, nil, size} when size in [nil, length(nodes)] ->
        named(nodes)

      {[_ | _] = nodes, nil, _size} ->
        {:error, "cluster.size: is the number of nodes, #{length(nodes)}, or left out"}

      {nil, dns, size} when is_binary(dns) and is_integer(size) ->
        {:ok, %__MODULE__{dns: dns, size: size}}

      {nil, dns, nil} when is_binary(dns) ->
        {:error, "cluster.size: is required with dns, as the number of nodes"}

      _neither ->
        {:error, "cluster: holds nodes, or dns and size"}
    end
  end

  defp named(names) do
    case Enum.reject(names, &(&1 =~ @short or &1 =~ @full)) do
      [] ->
        nodes = Enum.map(names, &node_name/1)
        {:ok, %__MODULE__{nodes: nodes, size: length(nodes)}}

      [name | _rest] ->
        {:error,
         "cluster.nodes: #{name} isn't a node; name one on this machine with letters, digits, - and _, or one elsewhere as wardrik@HOST"}
    end
  end

  @doc """
  Returns the node `name` names, as `WARDRIK_NODE` or `cluster.nodes` gives it.

      :wardrik_a@localhost = WardrikDaemon.Cluster.node_name("a")
      :wardrik@box1 = WardrikDaemon.Cluster.node_name("wardrik@box1")
  """
  @spec node_name(String.t()) :: node()
  def node_name(name) do
    # reach:disable-next-line unsafe_atom_creation -- a node name is an atom, one per node config.yaml names
    if name =~ "@", do: String.to_atom(name), else: String.to_atom("wardrik_#{name}@localhost")
  end

  @doc "Returns why this node can't be one of `cluster`'s, or `nil` if it can."
  @spec refusal(t() | nil, node()) :: String.t() | nil
  def refusal(%__MODULE__{nodes: [_ | _] = nodes}, node) do
    if node not in nodes,
      do:
        "#{node} isn't one of cluster.nodes: #{Enum.join(nodes, ", ")}. Start one of them with --node."
  end

  def refusal(_cluster, _node), do: nil

  @doc "Returns the children that connect this node to the rest of `cluster`: none without one."
  @spec children(t() | nil, node()) :: [{module(), term()}]
  def children(nil, _node), do: []

  def children(%__MODULE__{} = cluster, node),
    do: [{Cluster.Supervisor, [[wardrik: topology(cluster, node)], [name: __MODULE__]]}]

  defp topology(%__MODULE__{dns: nil, nodes: nodes}, _node),
    do: [strategy: Cluster.Strategy.Epmd, config: [hosts: nodes, timeout: @poll]]

  defp topology(%__MODULE__{dns: dns}, node),
    do: [
      strategy: Cluster.Strategy.DNSPoll,
      config: [query: dns, node_basename: basename(node), polling_interval: @poll]
    ]

  defp basename(node) do
    node
    |> Atom.to_string()
    |> String.split("@", parts: 2)
    |> hd()
  end

  @doc "Returns the options the EKV store counts its quorum with: a quorum of one without a cluster."
  @spec store_options(t() | nil) :: keyword()
  def store_options(nil), do: []

  def store_options(%__MODULE__{size: size}),
    do: [cluster_size: size, wait_for_quorum: @quorum_wait]
end
