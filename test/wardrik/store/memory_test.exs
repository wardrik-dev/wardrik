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

  test "provides no DurableServer backend" do
    refute function_exported?(Memory, :durable_backend, 1)
  end
end
