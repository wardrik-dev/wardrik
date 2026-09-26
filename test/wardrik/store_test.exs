defmodule Wardrik.StoreTest do
  use ExUnit.Case, async: false

  alias Wardrik.Store

  test "the configured adapter is the EKV one in this suite" do
    assert Store.adapter() == Wardrik.Store.EKV
  end

  test "config/0 is the adapter's options without the adapter" do
    assert Keyword.has_key?(Store.config(), :data_dir)
    refute Keyword.has_key?(Store.config(), :adapter)
  end

  test "reads and writes go through the adapter" do
    key = "probe/#{System.unique_integer([:positive])}"

    assert {:ok, _vsn} = Store.put(:store_test, key, :ok)
    assert Store.get(:store_test, key) == :ok
    assert {:ok, _vsn} = Store.lookup(:store_test, key)
    assert key in Store.keys(:store_test, "probe/")
    assert :ok = Store.delete(:store_test, key)
    assert Store.get(:store_test, key) == nil
  end

  test "durable_backend/0 is the adapter's" do
    assert {DurableServer.Backends.EKVStore, _opts} = Store.durable_backend()
  end
end
