defmodule WardrikStore.EKVTest do
  use ExUnit.Case, async: false
  use WardrikStore.Conformance

  alias WardrikStore.EKV

  setup_all do
    dir = Path.join(System.tmp_dir!(), "wardrik-ekv-test-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(dir) end)
    store = WardrikStore.new(adapter: EKV, name: :ekv_conformance, data_dir: dir)
    start_supervised!({WardrikStore, store})
    %{store: store}
  end

  test "names its EKV instance :wardrik_store unless named" do
    assert WardrikStore.new(data_dir: "/nowhere").name == :wardrik_store
  end

  describe "data_dir/1" do
    test "takes what it was configured with" do
      assert EKV.data_dir(data_dir: "/var/lib/wardrik") == "/var/lib/wardrik"
    end

    test "falls back to the environment" do
      System.put_env("WARDRIK_DATA_DIR", "/from/env")
      on_exit(fn -> System.delete_env("WARDRIK_DATA_DIR") end)

      assert EKV.data_dir() == "/from/env"
    end

    test "names the node, so two on one machine are two stores" do
      assert EKV.data_dir() =~ to_string(node())
    end
  end

  describe "cluster_size/1" do
    test "takes what it was configured with" do
      assert EKV.cluster_size(cluster_size: 5) == 5
    end

    test "falls back to the environment, then to one" do
      assert EKV.cluster_size() == 1

      System.put_env("WARDRIK_CLUSTER_SIZE", "3")
      on_exit(fn -> System.delete_env("WARDRIK_CLUSTER_SIZE") end)

      assert EKV.cluster_size() == 3
    end

    test "ignores an environment value that is not a number" do
      System.put_env("WARDRIK_CLUSTER_SIZE", "three")
      on_exit(fn -> System.delete_env("WARDRIK_CLUSTER_SIZE") end)

      assert EKV.cluster_size() == 1
    end
  end

  describe "shutdown_barrier/1" do
    test "keeps a store of several members serving for five seconds as it stops" do
      assert EKV.shutdown_barrier(cluster_size: 3) == 5_000
    end

    test "stops a store of one member at once" do
      assert EKV.shutdown_barrier(cluster_size: 1) == false
    end

    test "takes what it was configured with" do
      assert EKV.shutdown_barrier(cluster_size: 3, shutdown_barrier: false) == false
      assert EKV.shutdown_barrier(shutdown_barrier: 250) == 250
    end
  end

  describe "check/1" do
    @describetag :tmp_dir

    test "finds a directory this node can write to", %{tmp_dir: dir} do
      assert WardrikStore.check(adapter: EKV, data_dir: dir) ==
               {:ok, "on this node's disk, at #{dir}"}
    end

    test "finds one not made yet, which the store makes", %{tmp_dir: dir} do
      dir = Path.join(dir, "store")

      assert WardrikStore.check(adapter: EKV, data_dir: dir) ==
               {:ok, "on this node's disk, at #{dir}, made as the store starts"}
    end

    test "refuses one it cannot write to, or a file", %{tmp_dir: dir} do
      locked = Path.join(dir, "locked")
      File.mkdir_p!(locked)
      File.chmod!(locked, 0o500)
      on_exit(fn -> File.chmod!(locked, 0o700) end)

      file = Path.join(dir, "file")
      File.write!(file, "")

      assert {:error, "on this node's disk, at " <> found} =
               WardrikStore.check(adapter: EKV, data_dir: locked)

      assert found =~ "which this node cannot write to"

      assert {:error, "on this node's disk, at " <> found} =
               WardrikStore.check(adapter: EKV, data_dir: file)

      assert found =~ "which is not a directory"

      assert {:error, "on this node's disk, at " <> found} =
               WardrikStore.check(adapter: EKV, data_dir: file <> "/x")

      assert found =~ "not a directory"
    end
  end

  test "counts a quorum of more than half the cluster", %{store: store} do
    assert Enum.map(1..5, &WardrikStore.quorum(store, &1)) == [1, 2, 2, 3, 3]
  end

  test "provides the fleet's DurableServer backend", %{store: store} do
    assert WardrikStore.durable_backend(store) ==
             {DurableServer.Backends.EKVStore, name: :ekv_conformance}
  end
end
