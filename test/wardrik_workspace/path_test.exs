defmodule WardrikWorkspace.PathTest do
  use ExUnit.Case, async: true

  alias WardrikWorkspace.Path

  describe "normalize/1" do
    test "keeps a relative path as it is, less its . segments and repeated slashes" do
      assert Path.normalize("notes/today.md") == {:ok, "notes/today.md"}
      assert Path.normalize("./notes//./today.md/") == {:ok, "notes/today.md"}
    end

    test "refuses what would reach outside the workspace, or names nothing" do
      for path <- ["/etc/passwd", "~/.ssh/id_rsa", "notes/../../x", "..", "", ".", "a\\b", "a\0b"] do
        assert {:error, _message} = Path.normalize(path), inspect(path)
      end

      assert {:error, "notes/../x climbs out of the workspace with .."} =
               Path.normalize("notes/../x")

      assert {:error, _message} = Path.normalize(String.duplicate("a", 1025))
      assert {:error, _message} = Path.normalize(3)
    end
  end

  describe "match?/2" do
    test "* stays within a directory, and ** crosses them" do
      assert Path.match?("notes/*.md", "notes/today.md")
      refute Path.match?("notes/*.md", "notes/2026/today.md")
      assert Path.match?("notes/**/*.md", "notes/2026/today.md")
      assert Path.match?("notes/**/*.md", "notes/today.md")
      assert Path.match?("**", "shared/team/findings/a.md")
      assert Path.match?("**/*.md", "a.md")
    end

    test "? is one character, and everything else is itself" do
      assert Path.match?("day-?.md", "day-1.md")
      refute Path.match?("day-?.md", "day-10.md")
      assert Path.match?("a+b (1).md", "a+b (1).md")
      refute Path.match?("a.md", "aXmd")
    end
  end
end
