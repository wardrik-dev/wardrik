defmodule WardrikDaemon.Cluster.Strategy do
  @moduledoc """
  How a `WardrikDaemon.Cluster.Topology` finds the nodes it connects to.

  A strategy is a struct holding what `config.yaml` gave it, and its module
  answers `c:nodes/1` with the nodes that belong in the cluster now. It may
  include this node, and nodes that are not up; the topology connects to the
  rest. `WardrikDaemon.Cluster.Epmd` and `WardrikDaemon.Cluster.DNSPoll` are the two
  `config.yaml` names.
  """

  @doc "The nodes `strategy` finds."
  @callback nodes(strategy :: struct()) :: [node()]

  @doc "Asks `strategy`'s module for its nodes."
  @spec nodes(struct()) :: [node()]
  def nodes(%module{} = strategy), do: module.nodes(strategy)
end
