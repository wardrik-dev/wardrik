defmodule WardrikWorkspace.Backend.Conformance do
  @moduledoc """
  The tests every `WardrikWorkspace.Backend` passes.

      defmodule MyBackend.Test do
        use ExUnit.Case, async: false
        use WardrikWorkspace.Backend.Conformance, backend: MyBackend
      end

  The backend is expected to be running. Each test writes to a tree of its own
  under `conformance/` and leaves it there, so the suite is safe to run
  against a backend other tests share.
  """

  defmacro __using__(opts) do
    quote bind_quoted: [backend: Keyword.fetch!(opts, :backend)] do
      @backend backend

      defp conformance_tree, do: "conformance/#{System.unique_integer([:positive])}"

      defp conformance_file(content),
        do: %WardrikWorkspace.File{
          content: content,
          by: "test/writer",
          run: "4bf92f3577b34da6a3ce929d0e0e4736",
          call: "test/writer/call_1",
          labels: ["outside"],
          at: ~U[2026-09-30 12:00:00.000000Z]
        }

      describe "#{inspect(@backend)} as a WardrikWorkspace.Backend" do
        test "a path nothing wrote is none" do
          assert @backend.read(conformance_tree(), "notes/none.md") == :none
        end

        test "hands back the file as it was written, with its version" do
          tree = conformance_tree()
          file = conformance_file("hello\n")

          assert {:ok, version} = @backend.write(tree, "notes/today.md", file, nil)
          assert @backend.read(tree, "notes/today.md") == {:ok, file, version}
        end

        test "writes where nothing is written only once" do
          tree = conformance_tree()

          assert {:ok, _version} = @backend.write(tree, "a.md", conformance_file("first"), nil)

          assert @backend.write(tree, "a.md", conformance_file("second"), nil) ==
                   {:error, :conflict}

          assert {:ok, %WardrikWorkspace.File{content: "first"}, _version} =
                   @backend.read(tree, "a.md")
        end

        test "writes over the version read, and no other" do
          tree = conformance_tree()
          {:ok, first} = @backend.write(tree, "a.md", conformance_file("first"), nil)

          assert {:ok, second} = @backend.write(tree, "a.md", conformance_file("second"), first)
          assert second != first

          assert @backend.write(tree, "a.md", conformance_file("third"), first) ==
                   {:error, :conflict}

          assert {:ok, %WardrikWorkspace.File{content: "second"}, ^second} =
                   @backend.read(tree, "a.md")
        end

        test "deletes only the version read" do
          tree = conformance_tree()
          {:ok, first} = @backend.write(tree, "a.md", conformance_file("first"), nil)
          {:ok, second} = @backend.write(tree, "a.md", conformance_file("second"), first)

          assert @backend.delete(tree, "a.md", first) == {:error, :conflict}
          assert @backend.delete(tree, "a.md", second) == :ok
          assert @backend.read(tree, "a.md") == :none
        end

        test "lists the files under a prefix of one tree, and none of another's" do
          tree = conformance_tree()
          {:ok, a} = @backend.write(tree, "notes/a.md", conformance_file("a"), nil)
          {:ok, _b} = @backend.write(tree, "notes/b.md", conformance_file("b"), nil)
          {:ok, _c} = @backend.write(tree, "other/c.md", conformance_file("c"), nil)
          {:ok, _d} = @backend.write(tree <> "0", "notes/d.md", conformance_file("d"), nil)

          assert {:ok, listed} = @backend.list(tree, "notes/")
          assert listed |> Enum.map(&elem(&1, 0)) |> Enum.sort() == ["notes/a.md", "notes/b.md"]

          assert {"notes/a.md", %WardrikWorkspace.File{content: "a"}, ^a} =
                   Enum.find(listed, &(elem(&1, 0) == "notes/a.md"))

          assert {:ok, [_a, _b, _c]} = @backend.list(tree, "")
        end

        test "keeps a tree apart from a tree named under it" do
          tree = conformance_tree()
          under = tree <> "/notes"

          {:ok, _outer} = @backend.write(tree, "notes/a.md", conformance_file("outer"), nil)
          assert {:ok, _inner} = @backend.write(under, "a.md", conformance_file("inner"), nil)

          assert {:ok, %WardrikWorkspace.File{content: "outer"}, _version} =
                   @backend.read(tree, "notes/a.md")

          assert {:ok, %WardrikWorkspace.File{content: "inner"}, _version} =
                   @backend.read(under, "a.md")

          assert {:ok, [{"notes/a.md", _outer_file, _outer_version}]} = @backend.list(tree, "")
          assert {:ok, [{"a.md", _inner_file, _inner_version}]} = @backend.list(under, "")
        end

        test "names the files under a prefix of one tree without reading them" do
          tree = conformance_tree()
          {:ok, _a} = @backend.write(tree, "notes/a.md", conformance_file("a"), nil)
          {:ok, _b} = @backend.write(tree, "MEMORY.md", conformance_file("b"), nil)
          {:ok, _c} = @backend.write(tree <> "0", "notes/c.md", conformance_file("c"), nil)

          assert {:ok, paths} = @backend.paths(tree, "")
          assert Enum.sort(paths) == ["MEMORY.md", "notes/a.md"]
          assert @backend.paths(tree, "notes/") == {:ok, ["notes/a.md"]}
        end

        test "keeps a path of any characters a path may hold" do
          tree = conformance_tree()
          path = "notes/ünïcode, spaces & (brackets)/100%.md"

          assert {:ok, _version} = @backend.write(tree, path, conformance_file("x"), nil)
          assert {:ok, %WardrikWorkspace.File{content: "x"}, _version} = @backend.read(tree, path)
          assert {:ok, [{^path, _file, _version}]} = @backend.list(tree, "notes/")
        end
      end
    end
  end
end
