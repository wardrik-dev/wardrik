defmodule WardrikBraveTest do
  use ExUnit.Case, async: true

  test "attaches web search to a host as web_search, once, with the key it searches with" do
    host = WardrikBrave.attach(Wardrik.Host.new(), api_key: "secret")

    assert Wardrik.Host.tools(host) == %{"web_search" => WardrikBrave.WebSearch}
    assert Wardrik.Host.settings(host, WardrikBrave.WebSearch) == [api_key: "secret"]

    assert Wardrik.Host.settings(WardrikBrave.attach(Wardrik.Host.new()), WardrikBrave.WebSearch) ==
             []

    assert_raise ArgumentError, fn -> WardrikBrave.attach(host) end
    assert_raise ArgumentError, fn -> WardrikBrave.attach(Wardrik.Host.new(), key: "secret") end
  end
end
