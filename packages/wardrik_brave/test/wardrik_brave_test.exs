defmodule WardrikBraveTest do
  use ExUnit.Case, async: true

  test "attaches web search to a host as web_search, once, taking no options" do
    host = WardrikBrave.attach(Wardrik.Host.new())

    assert Wardrik.Host.tools(host) == %{"web_search" => WardrikBrave.WebSearch}
    assert_raise ArgumentError, fn -> WardrikBrave.attach(host) end
    assert_raise ArgumentError, fn -> WardrikBrave.attach(Wardrik.Host.new(), key: "secret") end
  end
end
