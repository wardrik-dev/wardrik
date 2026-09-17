defmodule TarsLua.RunTest do
  use ExUnit.Case, async: true

  alias Tars.Sandbox.Limits
  alias Tars.Tool.Result
  alias TarsLua.Run

  defp call(code, tool \\ Run.tool()), do: ReqLLM.Tool.execute(tool, %{"code" => code})

  describe "tool/0" do
    test "is a tool an agent can be configured with" do
      assert %Tars.LLM.Config{} = Tars.LLM.Config.new(tools: [Run])
      assert %ReqLLM.Tool{name: "run_lua"} = tool = Run.tool()
      assert tool.description =~ "Lua 5.3"
    end

    test "asks for the code and nothing else" do
      assert {:error, error} = ReqLLM.Tool.execute(Run.tool(), %{})
      assert Exception.message(error) =~ "code"
    end
  end

  describe "run_lua" do
    test "answers with the value the code returned" do
      assert {:ok, answer} = call("return 6 * 7")
      assert Result.ok?({:ok, answer})
      assert answer["result"] == %{"value" => 42}
    end

    test "answers a chunk that returned nothing by saying how to return one" do
      assert {:ok, answer} = call("x = 1")
      assert Result.ok?({:ok, answer})
      assert answer["result"]["value"] == nil
      assert answer["result"]["note"] =~ "`return <value>`"
    end

    test "reports code that would not run as a failed call, not a failed tool" do
      assert {:ok, answer} = call("return ++")
      refute Result.ok?({:ok, answer})
      assert answer["error"]["code"] == "lua_failed"
      assert answer["error"]["message"] =~ "Failed to compile Lua"
    end

    test "reports what the sandbox refused, so the model can try another way" do
      assert {:ok, answer} = call("return os.getenv('HOME')")
      refute Result.ok?({:ok, answer})
      assert answer["error"]["message"] =~ "sandboxed"
    end
  end

  describe "tool/1" do
    test "runs under limits of its own" do
      tool = Run.tool(limits: Limits.new(max_steps: 1_000))

      assert {:ok, answer} = call("while true do end", tool)
      assert answer["error"]["message"] =~ "instruction budget exceeded"
    end

    test "keeps the default limits for anything it is not given" do
      assert {:ok, answer} = call("return 1", Run.tool(limits: Limits.new(timeout_ms: 5_000)))
      assert answer["result"] == %{"value" => 1}
    end
  end
end
