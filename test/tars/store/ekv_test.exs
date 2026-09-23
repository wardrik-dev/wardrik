defmodule Tars.Store.EKVTest do
  use ExUnit.Case, async: false
  use Tars.Store.Conformance, adapter: Tars.Store.EKV

  alias Tars.Store.EKV

  describe "data_dir/1" do
    test "takes what it was configured with" do
      assert EKV.data_dir(data_dir: "/var/lib/tars") == "/var/lib/tars"
    end

    test "falls back to the environment" do
      System.put_env("TARS_DATA_DIR", "/from/env")
      on_exit(fn -> System.delete_env("TARS_DATA_DIR") end)

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

      System.put_env("TARS_CLUSTER_SIZE", "3")
      on_exit(fn -> System.delete_env("TARS_CLUSTER_SIZE") end)

      assert EKV.cluster_size() == 3
    end

    test "ignores an environment value that is not a number" do
      System.put_env("TARS_CLUSTER_SIZE", "three")
      on_exit(fn -> System.delete_env("TARS_CLUSTER_SIZE") end)

      assert EKV.cluster_size() == 1
    end
  end

  test "provides the fleet's DurableServer backend" do
    assert {DurableServer.Backends.EKVStore, name: :tars_store} = EKV.durable_backend([])
  end
end
