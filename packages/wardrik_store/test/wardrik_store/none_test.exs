defmodule WardrikStore.NoneTest do
  use ExUnit.Case, async: true

  setup do
    %{store: WardrikStore.new(adapter: WardrikStore.None)}
  end

  test "starts nothing", %{store: store} do
    assert {Function, :identity, [:ignore]} = WardrikStore.child_spec(store).start
  end

  test "raises on every read and write, saying no store is named", %{store: store} do
    for call <- [
          fn -> WardrikStore.put(store, :ns, "k", 1) end,
          fn -> WardrikStore.get(store, :ns, "k") end,
          fn -> WardrikStore.lookup(store, :ns, "k") end,
          fn -> WardrikStore.delete(store, :ns, "k") end,
          fn -> WardrikStore.keys(store, :ns) end,
          fn -> WardrikStore.durable_backend(store) end
        ] do
      assert_raise ArgumentError, "the host names no store; see Wardrik.Host", call
    end
  end

  test "is not a store to check, and needs no other node", %{store: store} do
    assert WardrikStore.check(adapter: WardrikStore.None) == {:error, "no store is named"}
    assert WardrikStore.quorum(store, 3) == 1
  end
end
