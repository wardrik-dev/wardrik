defmodule WardrikLuaTest do
  use ExUnit.Case, async: true

  defp run_lua(code, opts \\ []) do
    [tool] = WardrikLua.tools(nil, opts)
    tool.run.(%{code: code}, WardrikCore.Context.new(agent_id: "acme/triage"))
  end

  test "offers run_lua, which changes nothing" do
    assert [%WardrikCore.Tool{name: "run_lua"} = tool] = WardrikLua.tools(nil, [])
    assert WardrikCore.Tool.annotation(tool, :read_only)
  end

  test "answers what the code returns" do
    assert run_lua("return 6 * 7") == {:ok, %{value: 42}}
    assert run_lua("return {a = 1, b = {2, 3}}") == {:ok, %{value: %{"a" => 1, "b" => [2, 3]}}}
    assert {:ok, %{value: year}} = run_lua("return tonumber(os.date('%Y'))")
    assert year >= 2026
  end

  test "says when the code returned nothing, or failed" do
    assert {:ok, %{value: nil, note: "the chunk ran and returned nothing" <> _}} =
             run_lua("local x = 1")

    assert {:error, _why} = run_lua("return io.open('/etc/passwd')")
    assert {:error, _why} = run_lua("return (")
  end

  test "returns only what reads as JSON" do
    assert run_lua("return {[1.5] = 'a', [true] = 'b'}") ==
             {:ok, %{value: %{"1.5" => "a", "true" => "b"}}}

    assert {:error, why} = run_lua("return '\\255'")
    assert why =~ "valid UTF-8"
    assert {:error, why} = run_lua("return function() end")
    assert why =~ "cannot return functions"
    assert {:error, why} = run_lua("return {[{}] = 1}")
    assert why =~ "keys must be strings"
    assert {:error, why} = run_lua("return {[1] = 'a', ['1'] = 'b', x = 2}")
    assert why =~ "collide"
  end

  test "stops code that runs past its limits" do
    assert {:error, why} = run_lua("while true do end", limits: [timeout_ms: 100])
    assert why =~ "longer than 100ms"
  end
end
