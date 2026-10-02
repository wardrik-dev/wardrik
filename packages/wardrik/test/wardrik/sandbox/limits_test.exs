defmodule Wardrik.Sandbox.LimitsTest do
  use ExUnit.Case, async: true

  alias Wardrik.Sandbox.Limits

  describe "new/1" do
    test "bounds an evaluation four ways by default" do
      limits = Limits.new()

      assert limits.timeout_ms == :timer.seconds(30)
      assert limits.max_heap_bytes == 64 * 1024 * 1024
      assert limits.max_steps == 10_000_000
      assert limits.max_depth == 200
    end

    test "takes a bound of its own for any of them" do
      limits = Limits.new(timeout_ms: 500, max_depth: 8)

      assert limits.timeout_ms == 500
      assert limits.max_depth == 8
      assert limits.max_steps == 10_000_000
    end

    test "lifts a limit given :infinity" do
      assert Limits.new(max_steps: :infinity).max_steps == :infinity
    end

    test "refuses a bound that is not a positive integer" do
      for bound <- [0, -1, 1.5, "lots", nil] do
        assert_raise ArgumentError, ~r/max_steps takes a positive integer/, fn ->
          Limits.new(max_steps: bound)
        end
      end
    end

    test "refuses a field it does not have" do
      assert_raise KeyError, fn -> Limits.new(max_sockets: 1) end
    end
  end
end
