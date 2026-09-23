defmodule Tars.LLM.ConfigTest do
  use ExUnit.Case, async: true

  alias Tars.LLM.Config
  alias Tars.Test.CountingSource
  alias Tars.Test.EchoTool

  defp tool!(name) do
    ReqLLM.Tool.new!(name: name, description: "test tool", callback: fn i -> {:ok, i} end)
  end

  test "new/1 defaults" do
    config = Config.new()

    assert config.tools == []
    assert {_provider, _opts} = config.model_spec
  end

  test "new/1 overrides" do
    tool = tool!("echo")
    config = Config.new(model_spec: {:test, model: "m"}, tools: [tool])

    assert config.model_spec == {:test, model: "m"}
    assert config.tools == [tool]
  end

  test "new/1 leaves the persona unset, so an agent has none until given one" do
    assert Config.new().system == nil
  end

  test "new/1 takes a persona" do
    assert Config.new(system: "You answer briefly.").system == "You answer briefly."
  end

  test "new/1 holds the specs as given, and tools/1 builds them" do
    config = Config.new(tools: [EchoTool])

    assert config.tools == [EchoTool]
    assert [%ReqLLM.Tool{name: "echo"}] = Config.tools(config)
  end

  test "tools/1 leaves an already-built tool alone, so building twice is safe" do
    once = Config.tools(Config.new(tools: [EchoTool]))

    assert Config.tools(Config.new(tools: once)) == once
  end

  describe "tool_timeout/2" do
    defmodule Patient do
      @behaviour Tars.Tool

      @impl true
      def tool do
        ReqLLM.Tool.new!(name: "patient", description: "slow", callback: fn _ -> {:ok, %{}} end)
      end

      @impl true
      def timeout, do: :timer.minutes(10)
    end

    test "reads what the tool declares" do
      assert Config.tool_timeout(Config.new(tools: [Patient]), "patient") == :timer.minutes(10)
    end

    test "what the config says wins" do
      config = Config.new(tools: [Patient], tool_timeouts: %{"patient" => 5})

      assert Config.tool_timeout(config, "patient") == 5
    end

    test "a tool from a source reads the timeout its source declares" do
      config = Config.new(tools: [{CountingSource, 2}])

      assert Config.tool_timeout(config, "counted_2") == :timer.seconds(90)
    end

    test "nil for a tool declaring none, or one the config does not have" do
      assert Config.tool_timeout(Config.new(tools: [EchoTool]), "echo") == nil
      assert Config.tool_timeout(Config.new(), "nope") == nil
    end
  end

  test "new/1 raises on a tool it cannot build" do
    assert_raise ArgumentError, fn -> Config.new(tools: [:no_such_tool]) end
  end

  test "add_tool/2 prepends without disturbing the rest of the config" do
    first = tool!("first")
    second = tool!("second")

    config =
      Config.new(model_spec: {:test, model: "m"})
      |> Config.add_tool(first)
      |> Config.add_tool(second)

    assert config.tools == [second, first]
    assert config.model_spec == {:test, model: "m"}
  end

  test "add_tool/2 takes a module as readily as a built tool" do
    assert [%ReqLLM.Tool{name: "echo"}] =
             Config.new() |> Config.add_tool(EchoTool) |> Config.tools()
  end

  test "add_tool/2 raises on a tool it cannot build" do
    assert_raise ArgumentError, fn -> Config.add_tool(Config.new(), :no_such_tool) end
  end

  describe "dump/1 and load/1" do
    test "a config built from modules comes back whole" do
      config = Config.new(model_spec: {:test, model: "m"}, system: "be brief", tools: [EchoTool])

      loaded = config |> Config.dump() |> Config.load()

      assert loaded == config
    end

    test "a tool this node cannot build is dropped, with a warning" do
      dumped = %{Config.dump(Config.new(tools: [EchoTool])) | tools: [EchoTool, No.Such.Tool]}

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert Config.load(dumped).tools == [EchoTool]
        end)

      assert log =~ "No.Such.Tool"
    end

    test "generation and iteration limits travel" do
      config = Config.new(generation: [max_tokens: 100], max_iterations: 3)

      loaded = config |> Config.dump() |> Config.load()

      assert loaded.generation == [max_tokens: 100]
      assert loaded.max_iterations == 3
    end

    test "a tool declaring a timeout keeps it" do
      config = Config.new(tools: [EchoTool], tool_timeouts: %{"echo" => 1_000})

      assert Config.load(Config.dump(config)).tool_timeouts == %{"echo" => 1_000}
    end

    test "a tool given inline is dropped by name" do
      inline = ReqLLM.Tool.new!(name: "inline", description: "d", callback: fn _ -> {:ok, 1} end)
      config = Config.new(tools: [EchoTool, inline])

      dumped = Config.dump(config)

      assert dumped.tools == [EchoTool]
      assert dumped.dropped_tools == ["inline"]
    end

    test "loading warns about the tools that could not travel" do
      inline = ReqLLM.Tool.new!(name: "inline", description: "d", callback: fn _ -> {:ok, 1} end)
      dumped = Config.dump(Config.new(tools: [inline]))

      log = ExUnit.CaptureLog.capture_log(fn -> assert %Config{} = Config.load(dumped) end)

      assert log =~ "inline"
    end

    test "a dump is plain data" do
      dumped = Config.dump(Config.new(tools: [EchoTool]))

      assert dumped == dumped |> :erlang.term_to_binary() |> :erlang.binary_to_term()
    end

    test "a source travels with its argument, and builds its tools again" do
      config = Config.new(tools: [{CountingSource, 2}])

      loaded = config |> Config.dump() |> Config.load()

      assert loaded.tools == [{CountingSource, 2}]
      assert Enum.map(Config.tools(loaded), & &1.name) == ~w(counted_1 counted_2)
    end

    test "a source this node cannot build is dropped, with a warning" do
      dumped = Config.dump(Config.new(tools: [{CountingSource, 1}]))
      dumped = %{dumped | tools: [{No.Such.Source, 1}]}

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert Config.load(dumped).tools == []
        end)

      assert log =~ "No.Such.Source"
    end
  end
end
