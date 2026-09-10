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
end
