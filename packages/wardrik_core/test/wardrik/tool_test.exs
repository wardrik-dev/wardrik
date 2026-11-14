defmodule Wardrik.ToolTest do
  use ExUnit.Case, async: true

  alias Wardrik.Tool

  setup do
    %{
      tool: Tool.new!(name: "echo", description: "echo", run: fn _args, _context -> {:ok, ""} end)
    }
  end

  test "keeps private data under the key of the package that owns it", %{tool: tool} do
    tool = Tool.put_private(tool, MyPackage, %{gated: true})

    assert %{gated: true} = Tool.get_private(tool, MyPackage)
    assert :none = Tool.get_private(tool, OtherPackage, :none)
  end

  test "update_private/4 sets the default first, then updates", %{tool: tool} do
    tool = Tool.update_private(tool, MyPackage, 1, &(&1 + 1))
    assert 1 = Tool.get_private(tool, MyPackage)

    tool = Tool.update_private(tool, MyPackage, 1, &(&1 + 1))
    assert 2 = Tool.get_private(tool, MyPackage)
  end

  test "annotate/2 adds facts any package can read", %{tool: tool} do
    tool = Tool.annotate(tool, read_only: true, timeout: 50)

    assert true == Tool.annotation(tool, :read_only)
    assert 50 == Tool.annotation(tool, :timeout)
    assert nil == Tool.annotation(tool, :idempotent)
    assert false == Tool.annotation(tool, :idempotent, false)
  end

  test "new!/1 takes annotations" do
    tool =
      Tool.new!(
        name: "echo",
        description: "echo",
        run: fn _, _ -> {:ok, ""} end,
        annotations: [idempotent: true]
      )

    assert true == Tool.annotation(tool, :idempotent)
  end

  test "offers the model a schema without patterns, and still checks calls against them" do
    agent = %{"type" => "string", "pattern" => "^\\P{Cc}+$"}

    schema = %{
      "type" => "object",
      "properties" => %{
        "agent" => agent,
        "pattern" => %{"type" => "string"},
        "names" => %{"type" => "array", "items" => %{"type" => "string", "pattern" => "^a"}}
      },
      "required" => ["agent"]
    }

    tool =
      Tool.new!(
        name: "find",
        description: "find",
        schema: schema,
        run: fn args, _ -> {:ok, args} end
      )

    assert %{"agent" => %{"type" => "string"}, "pattern" => _kept, "names" => names} =
             tool.req_llm.parameter_schema["properties"]

    assert names["items"] == %{"type" => "string"}
    assert tool.schema["properties"]["agent"] == agent

    call = fn args -> %Wardrik.ToolCall{id: "1", name: "find", arguments: args} end
    assert {:ok, _args} = Tool.call([tool], call.(%{"agent" => "acme/a"}), %Wardrik.Context{})
    assert {:error, _why} = Tool.call([tool], call.(%{"agent" => "a\nb"}), %Wardrik.Context{})
  end

  test "rejects options it doesn't know" do
    assert_raise KeyError, fn ->
      Tool.new!(name: "echo", description: "echo", run: fn _, _ -> {:ok, ""} end, meta: %{})
    end
  end
end
