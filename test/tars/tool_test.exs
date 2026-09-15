defmodule Tars.ToolTest do
  use ExUnit.Case, async: true

  alias Tars.Test.EchoTool
  alias Tars.Tool

  defmodule NotATool do
    @moduledoc false
  end

  test "resolve!/1 builds a tool from a module" do
    assert [%ReqLLM.Tool{name: "echo"}] = Tool.resolve!([EchoTool])
  end

  test "resolve!/1 passes an inline tool through untouched" do
    inline = ReqLLM.Tool.new!(name: "inline", description: "d", callback: fn i -> {:ok, i} end)

    assert Tool.resolve!([inline]) == [inline]
  end

  test "resolve!/1 keeps order and mixes both forms" do
    inline = ReqLLM.Tool.new!(name: "inline", description: "d", callback: fn i -> {:ok, i} end)

    assert Tool.resolve!([EchoTool, inline]) |> Enum.map(& &1.name) == ["echo", "inline"]
  end

  test "resolve!/1 of nothing is nothing" do
    assert Tool.resolve!([]) == []
  end

  test "resolve!/1 rejects a module that does not implement the behaviour" do
    assert_raise ArgumentError, ~r/does not implement Tars.Tool/, fn ->
      Tool.resolve!([NotATool])
    end
  end

  test "resolve!/1 rejects a module that cannot be loaded" do
    assert_raise ArgumentError, ~r/cannot be loaded/, fn ->
      Tool.resolve!([:no_such_tool_module])
    end
  end

  test "resolve!/1 rejects anything that is not a module or a tool" do
    assert_raise ArgumentError, ~r/expected a tool module/, fn ->
      Tool.resolve!(["web_search"])
    end
  end

  describe "timeouts/2" do
    defmodule Patient do
      @behaviour Tars.Tool

      @impl true
      def tool do
        ReqLLM.Tool.new!(name: "patient", description: "slow", callback: fn _ -> {:ok, %{}} end)
      end

      @impl true
      def timeout, do: :timer.minutes(10)
    end

    test "reads what a module declares" do
      assert Tool.timeout(Patient) == :timer.minutes(10)
    end

    test "a module that declares none, or an inline tool, declares none" do
      tool = ReqLLM.Tool.new!(name: "x", description: "x", callback: fn _ -> {:ok, %{}} end)

      assert Tool.timeout(Tars.Test.EchoTool) == nil
      assert Tool.timeout(tool) == nil
    end
  end

  describe "available?/1" do
    test "a module implementing the behaviour, or an inline tool, is available" do
      tool = ReqLLM.Tool.new!(name: "x", description: "x", callback: fn _ -> {:ok, %{}} end)

      assert Tool.available?(Tars.Test.EchoTool)
      assert Tool.available?(tool)
    end

    test "a module that is missing or does not implement it is not" do
      refute Tool.available?(No.Such.Module)
      refute Tool.available?(Enum)
    end
  end
end
