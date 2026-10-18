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

  describe "with an argument" do
    test "names each subject of a call it matches, and never the tool whole" do
      pattern = Pattern.parse!("shell(git diff *)")

      assert Pattern.argument?(pattern)
      assert Pattern.match?(pattern, "shell", "git diff HEAD")
      refute Pattern.match?(pattern, "shell", "git push origin")
      refute Pattern.match?(pattern, "shells", "git diff HEAD")
      refute Pattern.match?(pattern, "shell")
      assert Pattern.match?(Pattern.parse!("github/*(acme/*)"), "github__create_issue", "acme/x")
    end

    test "is none of a server's, and one without an argument names no subject" do
      assert Pattern.server(Pattern.parse!("linear/*(x)")) == nil
      refute Pattern.argument?(Pattern.parse!("shell"))
      refute Pattern.match?(Pattern.parse!("shell"), "shell", "git status")
    end

    test "is written in parentheses at the end, and nowhere else" do
      assert {:error, message} = Pattern.parse("shell(git status")

      assert message ==
               "\"shell(git status\", which opens a parenthesis it never closes; a [ ] list " <>
                 "splits a rule at its commas, so quote a rule with several conditions there, " <>
                 "as \"tool(a > 1, b = 2)\", or write the rules one to a line, each after a -"

      assert {:error, message} = Pattern.parse("b = 2)")
      assert message =~ "closes a parenthesis it never opens; a [ ] list splits a rule"

      assert {:error, message} = Pattern.parse("(x)")
      assert message =~ "which is not a tool pattern; what a call acts on goes in parentheses"
      assert to_string(Pattern.parse!("shell(git status)")) == "shell(git status)"
    end
  end

  test "a pattern is text" do
    assert {:error, _message} = Pattern.parse("")
    assert {:error, _message} = Pattern.parse(3)
    assert to_string(Pattern.parse!("linear/*")) == "linear/*"
  end
end
