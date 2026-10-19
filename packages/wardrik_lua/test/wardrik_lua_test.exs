defmodule WardrikLuaTest do
  use ExUnit.Case, async: true

  test "attaches run_lua among the host's tools" do
    host = WardrikLua.attach(Wardrik.Host.new())

    assert Wardrik.Host.tools(host) == %{"run_lua" => WardrikLua.Run}
    assert_raise ArgumentError, fn -> WardrikLua.attach(Wardrik.Host.new(), limits: []) end
  end
end
