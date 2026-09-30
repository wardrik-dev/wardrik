defmodule Wardrik.ToolTest do
  use ExUnit.Case, async: true

  alias Wardrik.Test.CountingSource
  alias Wardrik.Test.EchoTool
  alias Wardrik.Tool

  defmodule NotATool do
    @moduledoc false
  end

  defmodule BadSource do
    @moduledoc false

    def tools(_argument), do: :not_a_list
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

  test "resolve!/1 expands a source into every tool it gives" do
    assert Tool.resolve!([{CountingSource, 3}]) |> Enum.map(& &1.name) ==
             ~w(counted_1 counted_2 counted_3)
  end

  test "resolve!/1 keeps a source's tools in place among the others" do
    assert Tool.resolve!([EchoTool, {CountingSource, 2}]) |> Enum.map(& &1.name) ==
             ~w(echo counted_1 counted_2)
  end

  test "resolve!/1 of a source with nothing to give is nothing" do
    assert Tool.resolve!([{CountingSource, []}]) == []
  end

  test "resolve!/1 rejects a source that cannot be loaded" do
    assert_raise ArgumentError, ~r/does not implement Wardrik.Tool tools\/1/, fn ->
      Tool.resolve!([{NotATool, :anything}])
    end
  end

  test "resolve!/1 rejects a source that gives something other than tools" do
    assert_raise ArgumentError, ~r/not a list of tools/, fn ->
      Tool.resolve!([{BadSource, :anything}])
    end
  end

  test "resolve!/1 rejects a module that does not implement the behaviour" do
    assert_raise ArgumentError, ~r/does not implement Wardrik.Tool/, fn ->
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
      @behaviour Wardrik.Tool

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

    test "a source declares one timeout for every tool it gives" do
      assert Tool.timeout({CountingSource, 3}) == :timer.seconds(90)
    end

    test "a module that declares none, or an inline tool, declares none" do
      tool = ReqLLM.Tool.new!(name: "x", description: "x", callback: fn _ -> {:ok, %{}} end)

      assert Tool.timeout(Wardrik.Test.EchoTool) == nil
      assert Tool.timeout(tool) == nil
    end
  end

  describe "in_doubt/2" do
    defmodule Rerunnable do
      @behaviour Wardrik.Tool

      @impl true
      def tool do
        ReqLLM.Tool.new!(name: "refund", description: "once", callback: fn _ -> {:ok, %{}} end)
      end

      @impl true
      def in_doubt("refund"), do: :rerun
    end

    defmodule KeyedSource do
      @behaviour Wardrik.Tool

      @impl true
      def tools(_argument), do: []

      @impl true
      def in_doubt(:mine, "refund"), do: :rerun
      def in_doubt(_argument, _name), do: :ask
    end

    test "reads what a module declares for its tool" do
      assert Tool.in_doubt(Rerunnable, "refund") == :rerun
    end

    test "asks a source with the argument it was named with" do
      assert Tool.in_doubt({KeyedSource, :mine}, "refund") == :rerun
      assert Tool.in_doubt({KeyedSource, :theirs}, "refund") == :ask
    end

    test "a module or source that declares nothing, or an inline tool, asks" do
      tool = ReqLLM.Tool.new!(name: "x", description: "x", callback: fn _ -> {:ok, %{}} end)

      assert Tool.in_doubt(EchoTool, "echo") == :ask
      assert Tool.in_doubt({CountingSource, 3}, "counted_1") == :ask
      assert Tool.in_doubt(tool, "x") == :ask
    end
  end

  describe "what a tool says about its calls" do
    alias Wardrik.Test.Tools.Deploy
    alias Wardrik.Test.Tools.Fetch

    defmodule DeclaringSource do
      @behaviour Wardrik.Tool

      @impl true
      def tools(_argument), do: []

      @impl true
      def gated?(:strict, _name), do: true
      def gated?(_argument, _name), do: false

      @impl true
      def subjects(argument, name, arguments), do: ["#{argument}:#{name}:#{arguments["path"]}"]

      @impl true
      def outside_content?(:web, _name), do: true
      def outside_content?(_argument, _name), do: false
    end

    test "is read from a module" do
      assert Tool.gated?(Deploy, "deploy")
      assert Tool.subjects(Deploy, "deploy", %{"target" => "prod"}) == ["prod"]
      refute Tool.outside_content?(Deploy, "deploy")
      assert Tool.outside_content?(Fetch, "fetch")
    end

    test "is asked of a source with the argument it was named with" do
      assert Tool.gated?({DeclaringSource, :strict}, "x")
      refute Tool.gated?({DeclaringSource, :lax}, "x")
      assert Tool.subjects({DeclaringSource, :a}, "x", %{"path" => "p"}) == ["a:x:p"]
      assert Tool.outside_content?({DeclaringSource, :web}, "x")
      refute Tool.outside_content?({DeclaringSource, :local}, "x")
    end

    test "is nothing where a module, a source or an inline tool declares nothing" do
      tool = ReqLLM.Tool.new!(name: "x", description: "x", callback: fn _ -> {:ok, %{}} end)

      for {spec, name} <- [{EchoTool, "echo"}, {{CountingSource, 3}, "counted_1"}, {tool, "x"}] do
        refute Tool.gated?(spec, name)
        assert Tool.subjects(spec, name, %{"a" => 1}) == []
        refute Tool.outside_content?(spec, name)
      end
    end
  end

  describe "available?/1" do
    test "a module implementing the behaviour, or an inline tool, is available" do
      tool = ReqLLM.Tool.new!(name: "x", description: "x", callback: fn _ -> {:ok, %{}} end)

      assert Tool.available?(Wardrik.Test.EchoTool)
      assert Tool.available?(tool)
    end

    test "a module that is missing or does not implement it is not" do
      refute Tool.available?(No.Such.Module)
      refute Tool.available?(Enum)
    end

    test "a source is available when its module gives tools" do
      assert Tool.available?({CountingSource, 3})
      refute Tool.available?({EchoTool, 3})
      refute Tool.available?({No.Such.Module, 3})
    end
  end

  describe "travels?/1" do
    test "a module and a source travel, an inline tool does not" do
      inline = ReqLLM.Tool.new!(name: "x", description: "x", callback: fn _ -> {:ok, %{}} end)

      assert Tool.travels?(EchoTool)
      assert Tool.travels?({CountingSource, 3})
      refute Tool.travels?(inline)
    end
  end

  describe "names/1" do
    test "names every tool a spec builds" do
      assert Tool.names(EchoTool) == ["echo"]
      assert Tool.names({CountingSource, 2}) == ~w(counted_1 counted_2)
    end
  end
end
