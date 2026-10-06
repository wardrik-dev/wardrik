defmodule WardrikLua.SandboxTest do
  use ExUnit.Case, async: true

  alias WardrikLua.Sandbox
  alias WardrikLua.Sandbox.Limits

  # The path the tool takes: core checks, bounds the process, and calls back in.
  defp evaluate(code, opts \\ []), do: Sandbox.run(code, Limits.new(opts))

  describe "check/1" do
    test "admits source within the size limit" do
      assert Sandbox.check("return 1 + 1") == :ok
    end

    test "leaves compilation to the bounded evaluation" do
      assert Sandbox.check("return ++") == :ok
    end

    test "refuses more source than it will take" do
      assert {:error, message} = Sandbox.check(String.duplicate("-- comment\n", 10_000))
      assert message =~ "longer than the 65536 allowed"
    end

    test "refuses anything that is not a string" do
      assert {:error, message} = Sandbox.check(:return_1)
      assert message =~ "code must be a string"
    end
  end

  describe "evaluate/2" do
    test "hands back the value a chunk returns" do
      assert evaluate("return 2 + 2") == {:ok, 4}
      assert evaluate(~s[return ("%d apples"):format(3)]) == {:ok, "3 apples"}
    end

    test "hands back several values as a list, and none as nil" do
      assert evaluate("return 1, 'two', true") == {:ok, [1, "two", true]}
      assert evaluate("x = 1") == {:ok, nil}
    end

    test "reads a table with keys 1..n as a list" do
      assert evaluate("local t = {} for i = 1, 4 do t[i] = i * i end return t") ==
               {:ok, [1, 4, 9, 16]}
    end

    test "reads any other table as a map, however deeply nested" do
      assert evaluate("return {a = 1, b = {c = {2, 3}}}") ==
               {:ok, %{"a" => 1, "b" => %{"c" => [2, 3]}}}
    end

    test "refuses code that does not parse without evaluating it" do
      assert {:error, message} = evaluate("return ++")
      assert message =~ "Failed to compile Lua"
    end

    test "reports an error the code raises as the sentence it raised" do
      assert {:error, message} = evaluate("error('nope')")
      assert message =~ "nope"
    end
  end

  describe "what the code cannot reach" do
    test "refuses every path out to the node" do
      for code <- [
            "return os.execute('ls')",
            "return os.getenv('HOME')",
            "return os.remove('/etc/passwd')",
            "return io.open('/etc/passwd')",
            "return io.write('x')",
            "return require('os')",
            "return load('return 1')",
            "return dofile('/etc/passwd')",
            "print('hello')",
            "return debug.getinfo(1)"
          ] do
        assert {:error, _message} = evaluate(code), "#{code} was not refused"
      end
    end

    test "says a refusal was the sandbox, so the model can stop trying" do
      assert {:error, message} = evaluate("return os.execute('ls')")
      assert message =~ "os.execute(_) is sandboxed"
    end

    test "leaves the harmless standard library alone" do
      assert {:ok, year} = evaluate("return os.date('!%Y')")
      assert year =~ ~r/^\d{4}$/
      assert evaluate("return math.max(2, 7), #'abc', utf8.len('héllo')") == {:ok, [7, 3, 5]}
    end
  end

  describe "limits" do
    test "bounds compilation by the deadline too" do
      code = "return " <> Enum.join(List.duplicate("1", 10_000), "+")
      task = Task.async(fn -> evaluate(code, timeout_ms: 10) end)
      result = Task.yield(task, 1_000) || Task.shutdown(task, :brutal_kill)

      assert {:ok, {:error, message}} = result
      assert message =~ "longer than 10ms"
    end

    test "stops code that spends its step budget" do
      assert {:error, message} = evaluate("while true do end", max_steps: 10_000)
      assert message =~ "instruction budget exceeded"
    end

    test "stops code that recurses past its depth" do
      assert {:error, message} =
               evaluate("local function f() return f() end return f()", max_depth: 20)

      assert message =~ "stack overflow"
    end

    test "refuses a string a quarter the size of the memory budget" do
      assert {:error, message} =
               evaluate("return string.rep('x', 10000000)", max_heap_bytes: 4_000_000)

      assert message =~ "resulting string too large"
    end

    test "stops code that runs past its deadline" do
      assert {:error, message} =
               evaluate("while true do end", timeout_ms: 50, max_steps: :infinity)

      assert message =~ "longer than 50ms"
    end

    test "stops code that holds more memory than it is allowed" do
      assert {:error, message} =
               evaluate(
                 "local t = {} for i = 1, 100000 do t[i] = string.rep('x', 10000) end return #t",
                 max_heap_bytes: 8_000_000,
                 timeout_ms: 10_000
               )

      assert message =~ "more memory than it is allowed"
    end

    test "runs unbounded work when every limit is lifted" do
      assert evaluate("return 1",
               timeout_ms: :infinity,
               max_steps: :infinity,
               max_depth: :infinity,
               max_heap_bytes: :infinity
             ) == {:ok, 1}
    end
  end
end
