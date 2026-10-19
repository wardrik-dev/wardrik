defmodule WardrikLua.RunTest do
  use ExUnit.Case, async: true

  alias Wardrik.Tool.Result
  alias WardrikLua.Run
  alias WardrikLua.Sandbox.Limits

  defp call(code, tool \\ Run.tool()) do
    run = Wardrik.Test.run(tools: [tool])
    Wardrik.Test.call(run, "run_lua", %{"code" => code}).result
  end

  describe "tool/0" do
    test "is a tool an agent can be configured with" do
      assert %Wardrik.LLM.Config{} = Wardrik.LLM.Config.new(tools: [Run])
      assert %Wardrik.Tool{name: "run_lua"} = tool = Run.tool()
      assert tool.description =~ "Lua 5.3"
    end

    test "asks for the code and nothing else" do
      assert {:error, error} = Wardrik.LLM.Tools.validate(Run.tool(), %{})
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

    test "reports values JSON cannot represent as serializable failures" do
      for code <- [
            "return string.char(255)",
            "return function() end",
            "return math.abs",
            "return {nested = {function() end}}",
            "local t = {} t.self = t return t",
            "return {[{}] = 1}",
            "return {[string.char(255)] = 1}"
          ] do
        assert {:ok, answer} = call(code)
        assert answer["ok"] == false, code
        assert answer["error"]["code"] == "lua_failed"
        assert is_binary(JSON.encode!(answer))
      end
    end

    test "refuses JSON key collisions even in nested tables" do
      for code <- [
            ~s(return {[1] = 10, ["1"] = 20}),
            ~s(return {nested = {[true] = 10, ["true"] = 20}})
          ] do
        assert {:ok, answer} = call(code)
        assert answer["error"]["code"] == "lua_failed"
        assert answer["error"]["message"] =~ "collide"
        assert is_binary(JSON.encode!(answer))
      end
    end

    test "preserves supported table entries through JSON" do
      assert {:ok, answer} = call("return {[2] = 'two', [false] = {1, 2}, name = 'ok'}")
      assert answer["result"]["value"] == %{"2" => "two", "false" => [1, 2], "name" => "ok"}
      assert answer |> Jason.encode!() |> Jason.decode!() == answer
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
