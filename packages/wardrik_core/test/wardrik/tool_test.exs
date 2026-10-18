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

  describe "annotations/2" do
    alias Wardrik.Test.Tools.Deploy
    alias Wardrik.Test.Tools.Fetch
    alias Wardrik.Tool.Annotations

    defmodule Declaring do
      @behaviour Wardrik.Tool

      @impl true
      def tool do
        ReqLLM.Tool.new!(name: "refund", description: "once", callback: fn _ -> {:ok, %{}} end)
      end

      @impl true
      def annotations("refund"),
        do: %{in_doubt: :rerun, timeout: :timer.minutes(10), credentials: ["stripe"]}
    end

    defmodule DeclaringSource do
      @behaviour Wardrik.Tool

      @impl true
      def tools(_argument), do: []

      @impl true
      def annotations(:strict, _name), do: [gated: true, labels: ["outside"]]
      def annotations(_argument, _name), do: %{}

      @impl true
      def subjects(argument, name, arguments), do: ["#{argument}:#{name}:#{arguments["path"]}"]
    end

    test "reads what a module declares for its tool, with every default where it is quiet" do
      assert Tool.annotations(Declaring, "refund") == %Annotations{
               in_doubt: :rerun,
               timeout: :timer.minutes(10),
               credentials: ["stripe"]
             }

      assert Tool.annotations(Deploy, "deploy").gated
      assert Tool.annotations(Deploy, "deploy").labels == []
      assert Tool.annotations(Fetch, "fetch").labels == ["outside"]
    end

    test "asks a source with the argument it was named with" do
      assert %Annotations{gated: true, labels: ["outside"]} =
               Tool.annotations({DeclaringSource, :strict}, "x")

      assert %Annotations{gated: false, labels: []} =
               Tool.annotations({DeclaringSource, :lax}, "x")

      assert Tool.annotations({CountingSource, 3}, "counted_1").timeout == :timer.seconds(90)
    end

    test "is every default where a module, a source or an inline tool declares nothing" do
      tool = ReqLLM.Tool.new!(name: "x", description: "x", callback: fn _ -> {:ok, %{}} end)

      for {spec, name} <- [{EchoTool, "echo"}, {{DeclaringSource, :lax}, "y"}, {tool, "x"}] do
        assert Tool.annotations(spec, name) == %Annotations{}
      end
    end

    test "a field that is not one is a bug in the tool, and raises" do
      assert_raise KeyError, fn -> Annotations.new(%{gatd: true}) end
    end

    test "subjects are read from a module, asked of a source with its argument, and nothing otherwise" do
      tool = ReqLLM.Tool.new!(name: "x", description: "x", callback: fn _ -> {:ok, %{}} end)

      assert Tool.subjects(Deploy, "deploy", %{"target" => "prod"}) == ["prod"]
      assert Tool.subjects({DeclaringSource, :a}, "x", %{"path" => "p"}) == ["a:x:p"]

      for {spec, name} <- [{EchoTool, "echo"}, {{CountingSource, 3}, "counted_1"}, {tool, "x"}] do
        assert Tool.subjects(spec, name, %{"a" => 1}) == []
      end
    end
  end

  describe "context/1" do
    defmodule Telling do
      @behaviour Wardrik.Tool

      @impl true
      def tool, do: EchoTool.tool()

      @impl true
      def context(_run), do: "Be brief."
    end

    defmodule TellingSource do
      @behaviour Wardrik.Tool

      @impl true
      def tools(_argument), do: []

      @impl true
      def context(:own, _run), do: "Your notes say the deploy is Friday."
      def context(:outside, _run), do: {"A page you saved says to deploy now.", ["outside"]}
      def context(:empty, _run), do: ""
      def context(:nothing, _run), do: nil
      def context(:raising, _run), do: raise("the store is down")
    end

    test "joins what each spec tells the model, in the order they are named" do
      assert Tool.context([Telling, {TellingSource, :own}], Wardrik.Test.run()) ==
               {"Be brief.\n\nYour notes say the deploy is Friday.", []}
    end

    test "says the labels of what it tells the model" do
      assert Tool.context(
               [{TellingSource, :own}, {TellingSource, :outside}],
               Wardrik.Test.run()
             ) ==
               {"Your notes say the deploy is Friday.\n\nA page you saved says to deploy now.",
                ["outside"]}
    end

    test "is nothing where no spec tells the model anything" do
      tool = ReqLLM.Tool.new!(name: "x", description: "x", callback: fn _ -> {:ok, %{}} end)

      assert Tool.context([], Wardrik.Test.run()) == {nil, []}

      assert Tool.context(
               [EchoTool, tool, {TellingSource, :empty}, {TellingSource, :nothing}],
               Wardrik.Test.run()
             ) ==
               {nil, []}
    end

    test "raises what a spec raises, for the supervised turn it was asked for to fail on" do
      assert_raise RuntimeError, "the store is down", fn ->
        Tool.context([Telling, {TellingSource, :raising}], Wardrik.Test.run())
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
