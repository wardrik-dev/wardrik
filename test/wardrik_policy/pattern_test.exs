defmodule WardrikPolicy.PatternTest do
  use ExUnit.Case, async: true

  alias WardrikPolicy.Pattern

  defp names?(source, name), do: source |> Pattern.parse!() |> Pattern.match?(name)

  test "a name matches only itself" do
    assert names?("web_search", "web_search")
    refute names?("web_search", "web_search_2")
  end

  test "an MCP tool is matched as server/tool" do
    assert names?("linear/list_issues", "linear__list_issues")
    assert names?("linear/*", "linear__list_issues")
    refute names?("linear/*", "github__list_issues")
    refute names?("linear/*", "linear_search")
  end

  test "an MCP tool is matched by the name the agent knows it by, too" do
    assert names?("github__delete_repo", "github__delete_repo")
    assert names?("github__*", "github__delete_repo")
    assert names?("*__delete_*", "github__delete_repo")
    refute names?("github__*", "linear__list_issues")
  end

  test "* stands for any run of characters, anywhere" do
    assert names?("*", "web_search")
    assert names?("*", "github__create_issue")
    assert names?("github/create_*", "github__create_issue")
    assert names?("*/delete_*", "linear__delete_issue")
    assert names?("a*b*c", "abxbc")
    refute names?("a*b*c", "abxbd")
    refute names?("github/create_*", "github__update_issue")
  end

  test "server/1 is the server a server/* pattern names" do
    assert Pattern.server(Pattern.parse!("linear/*")) == "linear"
    assert Pattern.server(Pattern.parse!("linear/list_*")) == nil
    assert Pattern.server(Pattern.parse!("*")) == nil
  end

  test "a pattern is text" do
    assert {:error, _message} = Pattern.parse("")
    assert {:error, _message} = Pattern.parse(3)
    assert to_string(Pattern.parse!("linear/*")) == "linear/*"
  end
end
