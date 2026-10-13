defmodule WardrikStore.MemoryInstanceTest do
  use ExUnit.Case, async: true

  alias WardrikStore.Memory

  setup do
    store =
      WardrikStore.new(adapter: Memory, name: :"memory_#{System.unique_integer([:positive])}")

    start_supervised!({WardrikStore, store})
    %{store: store}
  end

  test "clear/1 forgets everything", %{store: store} do
    {:ok, _vsn} = WardrikStore.put(store, :clear, "a", 1)
    :ok = Memory.clear(store)

    assert WardrikStore.get(store, :clear, "a") == nil
  end

  test "an instance of its own holds what is written to it, and nothing else", %{store: store} do
    {:ok, vsn} = WardrikStore.put(store, :mine, "a", 1)

    assert WardrikStore.lookup(store, :mine, "a") == {1, vsn}
    assert {:error, :conflict} = WardrikStore.delete(store, :mine, "a", if_vsn: vsn + 1)
    assert :ok = WardrikStore.delete(store, :mine, "a", if_vsn: vsn)
    assert WardrikStore.lookup(store, :mine, "a") == nil
  end

  test "lists the keys under a prefix in order, and none past it or in another namespace", %{
    store: store
  } do
    for key <- ~w(b/2 a b/1 b c ba), do: {:ok, _vsn} = WardrikStore.put(store, :listed, key, key)
    {:ok, _vsn} = WardrikStore.put(store, :other, "b/3", 3)
    {:ok, _vsn} = WardrikStore.put(store, :zzz, "b/4", 4)

    assert WardrikStore.keys(store, :listed, "b") == ~w(b b/1 b/2 ba)
    assert WardrikStore.keys(store, :listed, "b/") == ~w(b/1 b/2)
    assert WardrikStore.keys(store, :listed, "") == ~w(a b b/1 b/2 ba c)
    assert WardrikStore.keys(store, :listed, "d") == []
    assert WardrikStore.keys(store, :nothing, "") == []
  end

  test "is kept in memory, and needs no other node" do
    assert WardrikStore.check(adapter: Memory) == {:ok, "in this node's memory"}
    assert WardrikStore.quorum(WardrikStore.new(adapter: Memory), 3) == 1
  end

  test "is named after the adapter unless named" do
    assert WardrikStore.new(adapter: Memory).name == Memory
  end

  test "holds a one-node fleet through WardrikStore.Durable", %{store: store} do
    assert WardrikStore.durable_backend(store) == {WardrikStore.Durable, store: store}
  end
end
