defmodule Tars.Fleet.SupervisorTest do
  use ExUnit.Case, async: true

  alias Tars.Fleet.Supervisor

  describe "data_dir/1" do
    test "takes what it was configured with" do
      assert Supervisor.data_dir(data_dir: "/var/lib/tars") == "/var/lib/tars"
    end

    test "falls back to the environment" do
      System.put_env("TARS_DATA_DIR", "/from/env")
      on_exit(fn -> System.delete_env("TARS_DATA_DIR") end)

      assert Supervisor.data_dir() == "/from/env"
    end

    test "names the node, so two on one machine are two stores" do
      assert Supervisor.data_dir() =~ to_string(node())
    end
  end

  describe "cluster_size/1" do
    test "takes what it was configured with" do
      assert Supervisor.cluster_size(cluster_size: 5) == 5
    end

    test "falls back to the environment, then to one" do
      assert Supervisor.cluster_size() == 1

      System.put_env("TARS_CLUSTER_SIZE", "3")
      on_exit(fn -> System.delete_env("TARS_CLUSTER_SIZE") end)

      assert Supervisor.cluster_size() == 3
    end

    test "ignores an environment value that is not a number" do
      System.put_env("TARS_CLUSTER_SIZE", "three")
      on_exit(fn -> System.delete_env("TARS_CLUSTER_SIZE") end)

      assert Supervisor.cluster_size() == 1
    end
  end

  test "the fleet is running, with a store under it" do
    assert Tars.Fleet.running?()
    assert is_pid(Process.whereis(Supervisor))
    assert EKV.put(Supervisor.store(), "probe/1", :ok) == :ok
    assert EKV.get(Supervisor.store(), "probe/1") == :ok
  end
end
