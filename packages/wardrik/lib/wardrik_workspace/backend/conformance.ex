defmodule WardrikWorkspace.Backend.Conformance do
  @moduledoc """
  The tests every `Wardrik.Workspace` passes.

      defmodule MyBackend.Test do
        use ExUnit.Case, async: false
        use WardrikWorkspace.Backend.Conformance

        setup do
          %{workspace: %MyApp.Workspace{bucket: bucket}}
        end
      end

  Each test is handed the `Wardrik.Workspace` under `:workspace` in the
  test's context. What it keeps files in is expected to be running. Each
  test writes to a tree of its own under `conformance/` and leaves it
  there, so the suite is safe to run against a workspace other tests share.
  """

  defmacro __using__(_opts) do
    quote bind_quoted: [] do
      import WardrikWorkspace.Backend.Conformance

      describe "a Wardrik.Workspace" do
        test "a path nothing wrote is none", %{workspace: workspace} do
          assert read(workspace, conformance_tree(), "notes/none.md") == :none
        end

        test "hands back the file as it was written, with its version", %{workspace: workspace} do
          tree = conformance_tree()
          file = conformance_file("hello\n")

          assert {:ok, version} =
                   write(workspace, tree, "notes/today.md", file, nil)

          assert read(workspace, tree, "notes/today.md") == {:ok, file, version}
        end

        test "writes where nothing is written only once", %{workspace: workspace} do
          tree = conformance_tree()

          assert {:ok, _version} =
                   write(workspace, tree, "a.md", conformance_file("first"), nil)

          assert write(workspace, tree, "a.md", conformance_file("second"), nil) ==
                   {:error, :conflict}

          assert {:ok, %WardrikWorkspace.File{content: "first"}, _version} =
                   read(workspace, tree, "a.md")
        end

        test "writes over the version read, and no other", %{workspace: workspace} do
          tree = conformance_tree()

          {:ok, first} =
            write(workspace, tree, "a.md", conformance_file("first"), nil)

          assert {:ok, second} =
                   write(workspace, tree, "a.md", conformance_file("second"), first)

          assert second != first

          assert write(workspace, tree, "a.md", conformance_file("third"), first) ==
                   {:error, :conflict}

          assert {:ok, %WardrikWorkspace.File{content: "second"}, ^second} =
                   read(workspace, tree, "a.md")
        end

        test "deletes only the version read", %{workspace: workspace} do
          tree = conformance_tree()

          {:ok, first} =
            write(workspace, tree, "a.md", conformance_file("first"), nil)

          {:ok, second} =
            write(workspace, tree, "a.md", conformance_file("second"), first)

          assert delete(workspace, tree, "a.md", first) ==
                   {:error, :conflict}

          assert delete(workspace, tree, "a.md", second) == :ok
          assert read(workspace, tree, "a.md") == :none
        end

        test "lists the files under a prefix of one tree, and none of another's", %{
          workspace: workspace
        } do
          tree = conformance_tree()

          {:ok, a} =
            write(workspace, tree, "notes/a.md", conformance_file("a"), nil)

          {:ok, _b} =
            write(workspace, tree, "notes/b.md", conformance_file("b"), nil)

          {:ok, _c} =
            write(workspace, tree, "other/c.md", conformance_file("c"), nil)

          {:ok, _d} =
            write(workspace, tree <> "0", "notes/d.md", conformance_file("d"), nil)

          assert {:ok, listed} = list(workspace, tree, "notes/")
          assert listed |> Enum.map(&elem(&1, 0)) |> Enum.sort() == ["notes/a.md", "notes/b.md"]

          assert {"notes/a.md", %WardrikWorkspace.File{content: "a"}, ^a} =
                   Enum.find(listed, &(elem(&1, 0) == "notes/a.md"))

          assert {:ok, [_a, _b, _c]} = list(workspace, tree, "")
        end

        test "keeps a tree apart from a tree named under it", %{workspace: workspace} do
          tree = conformance_tree()
          under = tree <> "/notes"

          {:ok, _outer} =
            write(workspace, tree, "notes/a.md", conformance_file("outer"), nil)

          assert {:ok, _inner} =
                   write(workspace, under, "a.md", conformance_file("inner"), nil)

          assert {:ok, %WardrikWorkspace.File{content: "outer"}, _version} =
                   read(workspace, tree, "notes/a.md")

          assert {:ok, %WardrikWorkspace.File{content: "inner"}, _version} =
                   read(workspace, under, "a.md")

          assert {:ok, [{"notes/a.md", _outer_file, _outer_version}]} =
                   list(workspace, tree, "")

          assert {:ok, [{"a.md", _inner_file, _inner_version}]} =
                   list(workspace, under, "")
        end

        test "names the files under a prefix of one tree without reading them", %{
          workspace: workspace
        } do
          tree = conformance_tree()

          {:ok, _a} =
            write(workspace, tree, "notes/a.md", conformance_file("a"), nil)

          {:ok, _b} =
            write(workspace, tree, "MEMORY.md", conformance_file("b"), nil)

          {:ok, _c} =
            write(workspace, tree <> "0", "notes/c.md", conformance_file("c"), nil)

          assert {:ok, paths} = paths(workspace, tree, "")
          assert Enum.sort(paths) == ["MEMORY.md", "notes/a.md"]
          assert paths(workspace, tree, "notes/") == {:ok, ["notes/a.md"]}
        end

        test "keeps a path of any characters a path may hold", %{workspace: workspace} do
          tree = conformance_tree()
          path = "notes/ünïcode, spaces & (brackets)/100%.md"

          assert {:ok, _version} =
                   write(workspace, tree, path, conformance_file("x"), nil)

          assert {:ok, %WardrikWorkspace.File{content: "x"}, _version} =
                   read(workspace, tree, path)

          assert {:ok, [{^path, _file, _version}]} =
                   list(workspace, tree, "notes/")
        end
      end
    end
  end

  @doc false
  def read(workspace, tree, path), do: Wardrik.Workspace.read(workspace, tree, path)

  @doc false
  def write(workspace, tree, path, file, version),
    do: Wardrik.Workspace.write(workspace, tree, path, file: file, version: version)

  @doc false
  def delete(workspace, tree, path, version),
    do: Wardrik.Workspace.delete(workspace, tree, path, version: version)

  @doc false
  def list(workspace, tree, prefix), do: Wardrik.Workspace.list(workspace, tree, prefix)

  @doc false
  def paths(workspace, tree, prefix), do: Wardrik.Workspace.paths(workspace, tree, prefix)

  @doc false
  def conformance_tree, do: "conformance/#{System.unique_integer([:positive])}"

  @doc false
  def conformance_file(content),
    do: %WardrikWorkspace.File{
      content: content,
      by: "test/writer",
      run: "4bf92f3577b34da6a3ce929d0e0e4736",
      call: "test/writer/call_1",
      labels: ["outside"],
      at: ~U[2026-09-30 12:00:00.000000Z]
    }
end
