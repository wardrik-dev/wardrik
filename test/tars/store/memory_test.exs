defmodule Tars.Store.MemoryTest do
  use ExUnit.Case, async: false

  alias Tars.Store.Memory

  setup_all do
    start_supervised!(Memory.child_spec([]))
    :ok
  end

  use Tars.Store.Conformance, adapter: Memory

  test "a value with a ttl is gone once it has passed" do
    {:ok, _vsn} = Memory.put(:ttl, "soon", :value, ttl_ms: 1)
    assert Memory.get(:ttl, "soon", []) in [:value, nil]

    {:ok, _vsn} = Memory.put(:ttl, "later", :value, ttl_ms: :timer.hours(1))
    assert Memory.get(:ttl, "later", []) == :value
  end

  test "clear/0 forgets everything" do
    {:ok, _vsn} = Memory.put(:clear, "a", 1, [])
    :ok = Memory.clear()

    assert Memory.get(:clear, "a", []) == nil
  end

  test "provides no DurableServer backend" do
    refute function_exported?(Memory, :durable_backend, 1)
  end
end
