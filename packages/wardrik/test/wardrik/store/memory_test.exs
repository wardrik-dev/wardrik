defmodule Wardrik.Store.MemoryTest do
  use ExUnit.Case, async: false

  alias Wardrik.Store.Memory

  setup_all do
    start_supervised!(Memory.child_spec([]))
    :ok
  end

  use Wardrik.Store.Conformance, adapter: Memory

  test "clear/0 forgets everything" do
    {:ok, _vsn} = Memory.put(:clear, "a", 1, [])
    :ok = Memory.clear()

    assert Memory.get(:clear, "a", []) == nil
  end

  test "is kept in memory, and needs no other node" do
    assert Memory.check([]) == {:ok, "in this node's memory"}
    assert Memory.quorum(3) == 1
  end

  test "holds a one-node fleet through Wardrik.Store.Durable" do
    assert Memory.durable_backend(discovery_interval_ms: 200) ==
             {Wardrik.Store.Durable, store: Memory, discovery_interval_ms: 200}
  end
end
