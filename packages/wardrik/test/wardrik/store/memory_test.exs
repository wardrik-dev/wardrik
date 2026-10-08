defmodule Wardrik.Store.MemoryTest do
  # The conformance suite runs on the adapter's own instance, which
  # `Wardrik.Store.DurableTest` starts too.
  use ExUnit.Case, async: false

  alias Wardrik.Store.Memory

  setup_all do
    start_supervised!(Memory.child_spec([]))
    :ok
  end

  use Wardrik.Store.Conformance, adapter: Memory
end
