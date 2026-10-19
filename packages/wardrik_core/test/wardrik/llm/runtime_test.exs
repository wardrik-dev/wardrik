defmodule Wardrik.LLM.RuntimeTest do
  use ExUnit.Case, async: true

  alias Wardrik.LLM.Config
  alias Wardrik.Runtime

  @runtime %Wardrik.LLM.Runtime{config: [tool_prices: %{"echo" => 0.01}]}
  @resolved %Runtime.Context{instructions: "Be brief.", tools: [Wardrik.Test.EchoTool]}

  test "reads a definition's model, rounds and compaction over what every agent gets" do
    fields = %{
      "model" => "test:m",
      "max_iterations" => "infinity",
      "compaction" => %{"at" => 0.5}
    }

    assert {:ok, %Config{} = config} = Runtime.read(@runtime, fields, @resolved)
    assert config.model_spec == "test:m"
    assert config.max_iterations == :infinity
    assert config.history == Wardrik.Compaction.new(at: 0.5)
    assert config.system == "Be brief."
    assert config.tools == [Wardrik.Test.EchoTool]
    assert config.tool_prices == %{"echo" => 0.01}

    assert {:ok, %Config{history: %Wardrik.History.All{}, max_iterations: 3}} =
             Runtime.read(@runtime, %{"compaction" => false, "max_iterations" => 3}, @resolved)
  end

  test "says why a definition's settings do not read" do
    for {fields, message} <- [
          {%{"model" => 1}, "model is a string"},
          {%{"max_iterations" => 0}, "max_iterations is a whole number, or infinity"},
          {%{"compaction" => "yes"}, "compaction is false, or a set of at, keep and window"},
          {%{"compaction" => %{"often" => 1}},
           "compaction often is not a setting; expected at, keep or window"},
          {%{"compaction" => %{"at" => 2}},
           "compaction at is a share of the window, between 0 and 1"},
          {%{"compaction" => %{"window" => 0}}, "compaction window is a whole number of tokens"}
        ],
        do: assert(Runtime.read(@runtime, fields, @resolved) == {:error, message})
  end
end
