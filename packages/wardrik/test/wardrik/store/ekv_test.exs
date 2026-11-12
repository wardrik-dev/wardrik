defmodule Wardrik.Store.EKVTest do
  use ExUnit.Case, async: true
  use Wardrik.Store.Conformance

  setup_all do
    dir = Path.join(System.tmp_dir!(), "wardrik_store_ekv_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)

    store = Wardrik.Store.EKV.new(name: :wardrik_store_test, data_dir: dir, log: false)
    start_supervised!({Wardrik.Store, store})
    %{store: store}
  end

  test "keeps its keys apart from others in the same instance", %{store: store} do
    :ok = EKV.put(:wardrik_store_test, "agents/digest", :agent)

    assert Wardrik.Store.keys(store) == Wardrik.Store.keys(store, "")
    refute "agents/digest" in Wardrik.Store.keys(store)
  end
end
