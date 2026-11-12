defmodule Wardrik.Store.ETSTest do
  use ExUnit.Case, async: true
  use Wardrik.Store.Conformance

  setup_all do
    store = Wardrik.Store.ETS.new(name: __MODULE__)
    start_supervised!({Wardrik.Store, store})
    %{store: store}
  end

  test "keeps two stores of different names apart", %{store: store} do
    other = Wardrik.Store.ETS.new(name: Wardrik.Store.ETSTest.Other)
    start_supervised!(Supervisor.child_spec({Wardrik.Store, other}, id: :other))

    {:ok, _vsn} = Wardrik.Store.put(store, "shared", :here)

    assert Wardrik.Store.get(other, "shared") == nil
  end
end
