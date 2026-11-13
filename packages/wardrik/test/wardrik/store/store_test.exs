defmodule Wardrik.StoreTest do
  use ExUnit.Case, async: true

  setup do
    %{store: Wardrik.Store.ETS.new(name: :unstarted)}
  end

  test "nests scopes", %{store: store} do
    nested =
      store
      |> Wardrik.Store.scope("mode")
      |> Wardrik.Store.scope("wardrik_vault")

    assert %Wardrik.Store{scope: "mode/wardrik_vault"} = nested
  end

  test "refuses a scope name that could be mistaken for a key", %{store: store} do
    for name <- ["", "a/b", "a:b", "Mode", "1st", "wardrik-vault"] do
      assert_raise ArgumentError, ~r/lowercase letters/, fn ->
        Wardrik.Store.scope(store, name)
      end
    end
  end
end
