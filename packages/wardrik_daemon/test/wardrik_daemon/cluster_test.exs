defmodule WardrikDaemon.ClusterTest do
  use ExUnit.Case, async: false

  alias WardrikDaemon.Test.Host

  import Wardrik.Test, only: [store: 0]
  use Mimic

  # Commands run over rpc build their callers on the daemon's host.
  setup do: Host.held()

  import ExUnit.CaptureLog

  alias WardrikDaemon.Cluster
  alias WardrikDaemon.Cluster.DNSPoll
  alias WardrikDaemon.Cluster.Epmd
  alias WardrikDaemon.Cluster.Quorum
  alias WardrikDaemon.Cluster.Topology

  defmodule Net do
    @moduledoc false
    def connect(test, node) do
      send(test, {:connect, node})
      node != :down@localhost
    end

    def connected(nodes), do: nodes
  end

  defmodule Resolver do
    @moduledoc false
    def resolve("wardrik.internal", addresses), do: addresses
  end

  defp cluster(settings), do: Host.put_section(Cluster, settings)

  defp settings, do: Keyword.get(Host.sections(), Cluster, [])

  defp named(nodes) do
    cluster(
      nodes: nodes,
      size: length(nodes),
      topologies: [%Topology{name: "nodes", strategy: %Epmd{hosts: nodes}}]
    )
  end

  describe "quorum" do
    test "is more than half the cluster" do
      assert Enum.map(1..5, &WardrikStore.quorum(store(), &1)) == [1, 2, 2, 3, 3]
    end

    test "without a cluster there is nothing to wait for or refuse" do
      cluster([])

      refute Cluster.configured?(settings())
      assert Cluster.size(settings()) == 1
      assert Cluster.waiting(settings(), store()) == nil
      assert Cluster.refusal(settings()) == nil
    end

    test "a node the cluster does not name is refused, and says which it does" do
      named([:wardrik_a@localhost, :wardrik_b@localhost])

      assert Cluster.refusal(settings()) ==
               "nonode@nohost is not one of cluster.nodes: a, b; start one of them with --node"

      assert Cluster.waiting(settings(), store()) == nil
    end

    test "a node short of a quorum says how many more it needs, and who it has" do
      named([node(), :wardrik_b@localhost, :wardrik_c@localhost])

      assert Cluster.members(settings()) == [node()]

      assert Cluster.waiting(settings(), store()) ==
               "nonode@nohost is waiting for 1 more node to reach a quorum of 2 of 3"
    end

    test "a node whose store is kept elsewhere waits for no other" do
      stub(WardrikStore, :quorum, fn _store, _size -> 1 end)
      named([node(), :wardrik_b@localhost, :wardrik_c@localhost])

      assert Cluster.quorum(settings(), store()) == 1
      assert Cluster.waiting(settings(), store()) == nil
    end

    test "a node that is a quorum on its own waits for nothing" do
      named([node()])

      assert Cluster.members(settings()) == [node()]
      assert Cluster.waiting(settings(), store()) == nil
    end
  end

  describe "the quorum gate" do
    test "starts nothing without a cluster" do
      cluster([])
      assert Quorum.start_link(store: store(), cluster: settings()) == :ignore
    end

    test "refuses a node the cluster does not name" do
      named([:wardrik_a@localhost])

      log =
        capture_log(fn ->
          assert {:error, _reason} = Quorum.start_link(store: store(), cluster: settings())
        end)

      assert log =~ "nonode@nohost is not one of cluster.nodes: a"
    end

    test "lets the fleet start once a quorum is connected" do
      named([node()])
      assert Quorum.start_link(store: store(), cluster: settings()) == :ignore
    end

    # Answers what a node short of a quorum is waiting for `times` times, then
    # that it has one.
    defp short_for(times) do
      calls = :counters.new(1, [])

      fn ->
        :counters.add(calls, 1, 1)
        if :counters.get(calls, 1) <= times, do: "waiting"
      end
    end

    test "waits until a node coming up makes a quorum" do
      waiting = short_for(2)
      task = Task.async(fn -> Quorum.await(waiting, :timer.hours(1)) end)

      send(task.pid, {:nodedown, :gone@localhost})
      send(task.pid, {:nodeup, :one@localhost})
      send(task.pid, {:nodeup, :two@localhost})

      assert Task.await(task) == :ok
    end

    test "asks again each time it has waited long enough to say so" do
      assert Quorum.await(short_for(3), 1) == :ok
    end
  end

  describe "the supervisor" do
    test "runs nothing without a cluster" do
      cluster([])
      assert {:ok, :undefined} = start_supervised({Cluster, settings()})
      assert {:ok, :undefined} = start_supervised({Quorum, store: store(), cluster: settings()})
    end

    test "runs a topology for the way the cluster is found, which a node that is not distributed ignores" do
      named([:wardrik_a@localhost, :wardrik_b@localhost])

      log = capture_log(fn -> start_supervised!({Cluster, settings()}) end)

      assert [{{Topology, "nodes"}, :undefined, :worker, _modules}] =
               Supervisor.which_children(Cluster)

      assert log =~ "Cluster topology nodes is not started: this node is not distributed"
    end
  end

  describe "a topology's poll" do
    # What a poll reaches and misses is logged at info, beneath the suite's level.
    setup do
      level = Logger.level()
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: level) end)
    end

    defp topology(strategy, connected) do
      %Topology{
        name: "test",
        strategy: strategy,
        connect: {Net, :connect, [self()]},
        list_nodes: {Net, :connected, [connected]}
      }
    end

    test "connects to each node found that is neither this one nor connected" do
      strategy = %Epmd{hosts: [node(), :up@localhost, :new@localhost, :down@localhost]}

      log =
        capture_log([level: :info], fn ->
          assert {_topology, unreached} =
                   Topology.poll(topology(strategy, [:up@localhost]), MapSet.new())

          assert MapSet.to_list(unreached) == [:down@localhost]
        end)

      assert_received {:connect, :new@localhost}
      assert_received {:connect, :down@localhost}
      refute_received {:connect, _node}

      assert log =~ "Connected to new@localhost, found by cluster topology test"
      assert log =~ "Could not reach down@localhost yet"
    end

    test "polls again after its interval" do
      topology = %{topology(%Epmd{hosts: [:new@localhost]}, []) | polling_interval: 1}

      capture_log(fn ->
        assert {:noreply, {^topology, _unreached}} =
                 Topology.handle_info(:poll, {topology, MapSet.new()})
      end)

      assert_received {:connect, :new@localhost}
      assert_receive :poll
    end

    test "reports a node it cannot reach once, until it is reached" do
      topology = topology(%Epmd{hosts: [:down@localhost]}, [])

      log =
        capture_log([level: :info], fn ->
          Topology.poll(topology, MapSet.new([:down@localhost]))
        end)

      refute log =~ "Could not reach"
      assert_received {:connect, :down@localhost}
    end
  end

  describe "dns_poll" do
    test "names a node at each address the query resolves to" do
      strategy = %DNSPoll{
        query: "wardrik.internal",
        node_basename: "wardrik",
        resolver: {Resolver, :resolve, [[{10, 0, 0, 1}, {0xFD00, 0, 0, 0, 0, 0, 0, 1}]]}
      }

      assert DNSPoll.nodes(strategy) == [:"wardrik@10.0.0.1", :"wardrik@fd00::1"]
    end

    test "takes this node's own basename unless given one" do
      strategy = %DNSPoll{
        query: "wardrik.internal",
        resolver: {Resolver, :resolve, [[{10, 0, 0, 2}]]}
      }

      assert DNSPoll.nodes(strategy) == [:"nonode@10.0.0.2"]
    end
  end

  describe "the CLI" do
    test "wardrik start keeps waiting while nothing has started" do
      cluster([])

      assert_raise RuntimeError, "wardrik is starting", fn -> WardrikDaemon.CLI.started() end
    end

    test "wardrik start is told what a node short of a quorum waits for" do
      named([node(), :wardrik_b@localhost, :wardrik_c@localhost])
      assert WardrikDaemon.CLI.started() =~ "is waiting for 1 more node"
    end

    test "wardrik start sees a node the cluster does not name fail" do
      named([:wardrik_a@localhost])

      assert_raise RuntimeError, ~r/is not one of cluster.nodes/, fn ->
        WardrikDaemon.CLI.started()
      end
    end

    test "a node that is not in a cluster stops the usual way" do
      cluster([])
      assert WardrikDaemon.CLI.stopping() == ""
    end

    defp command(args) do
      ExUnit.CaptureIO.capture_io(fn ->
        try do
          WardrikDaemon.CLI.main(args)
        catch
          :exit, {:shutdown, 1} -> IO.write("[exit 1]")
        end
      end)
    end

    test "a node short of a quorum answers every command with what it waits for" do
      named([node(), :wardrik_b@localhost, :wardrik_c@localhost])

      assert command(["status"]) =~ ~r/^nonode@nohost is waiting for 1 more node.*\n$/
      assert command(["parked"]) =~ ~r/is waiting for 1 more node.*\n\[exit 1\]$/
    end

    test "wardrik status counts what DNS finds" do
      cluster(
        size: 3,
        topologies: [
          %Topology{
            name: "dns",
            strategy: %DNSPoll{query: "wardrik.internal", resolver: {Resolver, :resolve, [[]]}}
          }
        ]
      )

      assert Cluster.waiting(settings(), store()) =~
               "is waiting for 2 more nodes to reach a quorum of 2 of 3"

      assert WardrikDaemon.status(
               Host.host(Host.agents()),
               Host.config(System.tmp_dir!())
             ) =~ "\ncluster of 3, found by DNS: none connected\n"
    end

    test "wardrik status says which of the cluster's nodes are connected" do
      named([node()])

      assert WardrikDaemon.status(
               Host.host(Host.agents()),
               Host.config(System.tmp_dir!())
             ) =~
               ~r/^wardrik .* on nonode@nohost, up .*\ncluster of 1: nonode@nohost up\n/
    end
  end
end
