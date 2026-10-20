defmodule WardrikBraveTest do
  use ExUnit.Case, async: true

  test "attaches web search to a host as web_search, once, with the key it searches with" do
    host = WardrikBrave.attach(Wardrik.Host.new(), api_key: "k-secret")

    assert Wardrik.Host.tools(host) == %{"web_search" => WardrikBrave.WebSearch}
    assert [api_key: key] = Wardrik.Host.settings(host, WardrikBrave.WebSearch)
    assert Wardrik.Credential.reveal(key) == "k-secret"
    refute inspect(host) =~ "k-secret"
    refute inspect(WardrikBrave.Config.new(api_key: "k-secret")) =~ "k-secret"

    assert Wardrik.Host.settings(WardrikBrave.attach(Wardrik.Host.new()), WardrikBrave.WebSearch) ==
             []

    assert_raise ArgumentError, fn -> WardrikBrave.attach(host) end
    assert_raise ArgumentError, fn -> WardrikBrave.attach(Wardrik.Host.new(), key: "k-secret") end
  end
end
