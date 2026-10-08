defmodule WardrikStore.MemoryTest do
  # The conformance suite runs on the adapter's own instance, which
  # `WardrikStore.DurableTest` starts too.
  use ExUnit.Case, async: false

  alias WardrikStore.Memory

  setup_all do
    start_supervised!(Memory.child_spec([]))
    :ok
  end

  use WardrikStore.Conformance, adapter: Memory
end
