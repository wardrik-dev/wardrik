defmodule WardrikStore.MemoryTest do
  use ExUnit.Case, async: true
  use WardrikStore.Conformance

  setup_all do
    store = WardrikStore.new(adapter: WardrikStore.Memory, name: :memory_conformance)
    start_supervised!({WardrikStore, store})
    %{store: store}
  end
end
