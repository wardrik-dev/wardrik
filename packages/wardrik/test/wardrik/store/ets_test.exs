defmodule WardrikStore.ETSTest do
  use ExUnit.Case, async: true
  use WardrikStore.Conformance

  setup_all do
    store = WardrikStore.ETS.new(name: __MODULE__)
    start_supervised!({WardrikStore, store})
    %{store: store}
  end

  test "keeps two stores of different names apart", %{store: store} do
    other = WardrikStore.ETS.new(name: WardrikStore.ETSTest.Other)
    start_supervised!(Supervisor.child_spec({WardrikStore, other}, id: :other))

    {:ok, _vsn} = WardrikStore.put(store, "shared", :here)

    assert WardrikStore.get(other, "shared") == nil
  end
end
