defmodule WardrikStoreTest do
  use ExUnit.Case, async: true

  alias WardrikStore.Memory

  setup do
    store =
      WardrikStore.new(adapter: Memory, name: :"store_#{System.unique_integer([:positive])}")

    start_supervised!({WardrikStore, store})
    %{store: store}
  end

  test "a store is its adapter and what the adapter's calls are handed", %{store: store} do
    assert %WardrikStore{adapter: Memory, config: name} = store
    assert Atom.to_string(name) =~ "store_"
  end

  test "settings naming no adapter name the EKV one" do
    assert %WardrikStore{adapter: WardrikStore.EKV, config: %{data_dir: "/nowhere"}} =
             WardrikStore.new(data_dir: "/nowhere")
  end

  test "reads and writes go through the adapter", %{store: store} do
    assert {:ok, vsn} = WardrikStore.put(store, :store_test, "probe/a", :ok)
    assert WardrikStore.get(store, :store_test, "probe/a") == :ok
    assert WardrikStore.lookup(store, :store_test, "probe/a") == {:ok, vsn}
    assert WardrikStore.keys(store, :store_test, "probe/") == ["probe/a"]
    assert WardrikStore.keys(store, :store_test) == ["probe/a"]
    assert :ok = WardrikStore.delete(store, :store_test, "probe/a")
    assert WardrikStore.get(store, :store_test, "probe/a") == nil
  end

  test "two stores on one node are two", %{store: store} do
    other =
      WardrikStore.new(adapter: Memory, name: :"other_#{System.unique_integer([:positive])}")

    start_supervised!({WardrikStore, other}, id: :other)

    {:ok, _vsn} = WardrikStore.put(store, :store_test, "a", 1)

    assert WardrikStore.get(other, :store_test, "a") == nil
  end

  test "the child runs the adapter's, under the store's id", %{store: store} do
    assert %{id: WardrikStore, start: {Memory, :start_link, [name]}} =
             WardrikStore.child_spec(store)

    assert name == store.config
  end

  test "check/1 asks the adapter the settings name, without starting it" do
    assert WardrikStore.check(adapter: Memory) == {:ok, "in this node's memory"}
  end

  test "an adapter this node does not have is named, with what the optional ones need" do
    message =
      "WardrikStoreTest.Absent is not a module this node has. WardrikEcto.Store needs " <>
        ":ecto_sql and :postgrex among the application's dependencies, and " <>
        "WardrikStore.EKV, the store where no adapter is named, needs :ekv"

    assert WardrikStore.check(adapter: WardrikStoreTest.Absent) == {:error, message}

    assert_raise ArgumentError, message, fn ->
      WardrikStore.new(adapter: WardrikStoreTest.Absent)
    end
  end

  test "quorum/2 is the store's adapter's", %{store: store} do
    assert WardrikStore.quorum(store, 3) == 1
    assert WardrikStore.quorum(WardrikStore.new(data_dir: "/nowhere"), 3) == 2
  end

  test "durable_backend/1 is the store's adapter's", %{store: store} do
    assert WardrikStore.durable_backend(store) == {WardrikStore.Durable, store: store}
  end
end
