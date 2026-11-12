defmodule WardrikStoreTest do
  use ExUnit.Case, async: true

  setup do
    %{store: WardrikStore.ETS.new(name: :unstarted)}
  end

  test "nests scopes", %{store: store} do
    assert %WardrikStore{scope: "mode/wardrik_vault"} =
             store |> WardrikStore.scope("mode") |> WardrikStore.scope("wardrik_vault")
  end

  test "refuses a scope name that could be mistaken for a key", %{store: store} do
    for name <- ["", "a/b", "a:b", "Mode", "1st", "wardrik-vault"] do
      assert_raise ArgumentError, ~r/lowercase letters/, fn -> WardrikStore.scope(store, name) end
    end
  end
end
