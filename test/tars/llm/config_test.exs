defmodule Tars.LLM.ConfigTest do
  use ExUnit.Case, async: true

  alias Tars.LLM.Config

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
end
