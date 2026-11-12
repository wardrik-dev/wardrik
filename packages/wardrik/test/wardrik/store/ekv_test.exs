defmodule WardrikStore.EKVTest do
  use ExUnit.Case, async: true
  use WardrikStore.Conformance

  setup_all do
    dir = Path.join(System.tmp_dir!(), "wardrik_store_ekv_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)

    store = WardrikStore.EKV.new(name: :wardrik_store_test, data_dir: dir, log: false)
    start_supervised!({WardrikStore, store})
    %{store: store}
  end

  test "keeps its keys apart from others in the same instance", %{store: store} do
    :ok = EKV.put(:wardrik_store_test, "agents/digest", :agent)

    assert WardrikStore.keys(store) == WardrikStore.keys(store, "")
    refute "agents/digest" in WardrikStore.keys(store)
  end
end
