defmodule Tars.LLM.ConfigTest do
  use ExUnit.Case, async: true

  alias Tars.LLM.Config
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

  test "new/1 builds the tools a config names by module" do
    config = Config.new(tools: [EchoTool])

    assert [%ReqLLM.Tool{name: "echo"}] = config.tools
  end

  test "new/1 leaves an already-built tool alone, so building twice is safe" do
    once = Config.new(tools: [EchoTool])

    assert Config.new(tools: once.tools).tools == once.tools
  end

  test "new/1 raises on a tool it cannot build" do
    assert_raise ArgumentError, fn -> Config.new(tools: [:no_such_tool]) end
  end

  test "test_tools/0 provides one tool per failure mode" do
    tools = Config.test_tools()

    assert Enum.map(tools, & &1.name) |> Enum.sort() == ["crash", "echo", "fail"]
    assert Enum.all?(tools, &match?(%ReqLLM.Tool{}, &1))
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
             Config.new() |> Config.add_tool(EchoTool) |> Map.fetch!(:tools)
  end

  describe "dump/1 and load/1" do
    test "a config built from modules comes back whole" do
      config = Config.new(model_spec: {:test, model: "m"}, system: "be brief", tools: [EchoTool])

      loaded = config |> Config.dump() |> Config.load()

      assert loaded.model_spec == {:test, model: "m"}
      assert loaded.system == "be brief"
      assert [%ReqLLM.Tool{name: "echo"}] = loaded.tools
      assert loaded.tool_specs == [EchoTool]
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
  end
end
