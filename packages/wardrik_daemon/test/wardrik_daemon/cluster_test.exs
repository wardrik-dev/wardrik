defmodule WardrikDaemon.ClusterTest do
  use ExUnit.Case, async: true

  alias WardrikDaemon.Cluster, as: DaemonCluster

  test "names nodes on this machine by their short names" do
    assert DaemonCluster.node_name("a") == :wardrik_a@localhost
    assert DaemonCluster.node_name("wardrik@box1") == :wardrik@box1
  end

  test "connects to the nodes it names, or those DNS finds" do
    {:ok, named} = DaemonCluster.new(nodes: ["a", "b"])

    assert [{Cluster.Supervisor, [[wardrik: topology], [name: DaemonCluster]]}] =
             DaemonCluster.children(named, :wardrik_a@localhost)

    assert topology[:strategy] == Cluster.Strategy.Epmd
    assert topology[:config][:hosts] == [:wardrik_a@localhost, :wardrik_b@localhost]

    {:ok, found} = DaemonCluster.new(dns: "wardrik.internal", size: 3)

    assert [{Cluster.Supervisor, [[wardrik: topology], _opts]}] =
             DaemonCluster.children(found, :w@x)

    assert topology[:strategy] == Cluster.Strategy.DNSPoll
    assert topology[:config][:query] == "wardrik.internal"
    assert topology[:config][:node_basename] == "w"

    assert DaemonCluster.children(nil, node()) == []
  end

  test "counts the store's quorum over the cluster's size" do
    {:ok, cluster} = DaemonCluster.new(dns: "wardrik.internal", size: 3)
    assert [cluster_size: 3, wait_for_quorum: _wait] = DaemonCluster.store_options(cluster)
    assert DaemonCluster.store_options(nil) == []
  end

  test "refuses a node the cluster doesn't name" do
    {:ok, cluster} = DaemonCluster.new(nodes: ["a", "b"])
    assert DaemonCluster.refusal(cluster, :wardrik_a@localhost) == nil
    assert DaemonCluster.refusal(cluster, :wardrik_c@localhost) =~ "isn't one of cluster.nodes"
    assert DaemonCluster.refusal(nil, node()) == nil
    {:ok, found} = DaemonCluster.new(dns: "wardrik.internal", size: 3)
    assert DaemonCluster.refusal(found, node()) == nil
  end
end
