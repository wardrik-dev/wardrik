defmodule WardrikWorkspace.Backend.StoreTest do
  use ExUnit.Case, async: true
  use WardrikWorkspace.Backend.Conformance, backend: WardrikWorkspace.Backend.Store

  alias WardrikWorkspace.Backend.Store
  alias WardrikWorkspace.File

  @file_written %File{
    content: "x",
    by: "test/writer",
    run: "4bf92f3577b34da6a3ce929d0e0e4736",
    call: "test/writer/call_1",
    labels: [],
    at: ~U[2026-09-30 12:00:00.000000Z]
  }

  describe "a tree or a path that is not normalised" do
    test "is refused as a tree, by every operation" do
      for tree <- ["", "/store-test", "store-test/", "store-test//notes"] do
        assert Store.read(tree, "a.md") == {:error, {:not_a_tree, tree}}
        assert Store.write(tree, "a.md", @file_written, nil) == {:error, {:not_a_tree, tree}}
        assert Store.delete(tree, "a.md", 1) == {:error, {:not_a_tree, tree}}
        assert Store.list(tree, "") == {:error, {:not_a_tree, tree}}
      end
    end

    test "is refused as a path, before anything is written" do
      tree = "store-test/#{System.unique_integer([:positive])}"

      for path <- ["", "/a.md", "notes/", "notes//a.md"] do
        assert Store.read(tree, path) == {:error, {:not_a_path, path}}
        assert Store.write(tree, path, @file_written, nil) == {:error, {:not_a_path, path}}
        assert Store.delete(tree, path, 1) == {:error, {:not_a_path, path}}
      end

      assert Store.list(tree, "") == {:ok, []}
    end
  end
end
