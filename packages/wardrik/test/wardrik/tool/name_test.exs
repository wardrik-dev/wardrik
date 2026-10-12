defmodule Wardrik.Tool.NameTest do
  use ExUnit.Case, async: true

  alias Wardrik.Tool.Name

  test "a tool is shown with its server's separator as a slash, once" do
    assert Name.shown("github__create_issue") == "github/create_issue"
    assert Name.shown("a__b__c") == "a/b__c"
    assert Name.shown("web_search") == "web_search"
  end

  test "a glob names a tool as the agent knows it or as it is shown" do
    assert Name.match?(Name.glob("github/create_*"), "github__create_issue")
    assert Name.match?(Name.glob("github__*"), "github__create_issue")
    assert Name.match?(Name.glob("*"), "web_search")
    refute Name.match?(Name.glob("linear/*"), "github__create_issue")
  end

  test "a name with no star matches itself whole" do
    assert Name.glob?(["web_search"], "web_search")
    refute Name.glob?(["web_search"], "web_search_deep")
  end

  test "stars match any run of characters, an empty one too" do
    assert Name.glob?(Name.glob("*search"), "web_search")
    assert Name.glob?(Name.glob("web*"), "web")
    assert Name.glob?(Name.glob("a**c"), "abc")
    assert Name.glob?(Name.glob("a*b*c"), "a-b-b-c")
    refute Name.glob?(Name.glob("a*b*c"), "a-c-b")
  end
end
