defmodule WardrikWorkspace.SpecTest do
  use ExUnit.Case, async: true

  alias WardrikWorkspace.Mount
  alias WardrikWorkspace.Spec

  describe "new/2" do
    test "gives an agent its own tree, and shares the trees its key reaches" do
      assert {:ok, spec} =
               Spec.new("acme/jon/triage", %{
                 "team" => "acme",
                 "runbooks" => %{"tree" => "acme/runbooks", "mode" => "read"},
                 "mine" => "acme/jon/notes/"
               })

      assert spec.tree == %Mount{tree: "agents/acme/jon/triage"}

      assert spec.shared == [
               %Mount{name: "mine", tree: "shared/acme/jon/notes"},
               %Mount{name: "runbooks", tree: "shared/acme/runbooks", mode: :read},
               %Mount{name: "team", tree: "shared/acme"}
             ]
    end

    test "refuses a tree under a scope the agent is not under" do
      assert Spec.new("acme/jon/triage", %{"theirs" => "globex/findings"}) ==
               {:error,
                "shared theirs: globex/findings belongs to globex/, which acme/jon/triage is not under"}

      assert {:error, _message} = Spec.new("acme/jon/triage", %{"hers" => "acme/ann/notes"})
    end

    test "refuses a name, a tree or a setting that does not read" do
      for {shared, said} <- [
            {%{"Team" => "acme"}, "is not a name"},
            {%{"team" => "acme/../x"}, "is not a tree"},
            {%{"team" => "acme/a/b/c"}, "has more than three parts"},
            {%{"team" => %{"tree" => "acme", "mode" => "rw"}}, "mode is read or write"},
            {%{"team" => %{"tree" => "acme", "size" => 1}}, "size is not a setting"},
            {%{"team" => 3}, "names a tree"}
          ] do
        assert {:error, message} = Spec.new("acme/jon/triage", shared)
        assert message =~ said
      end
    end
  end

  describe "resolve/2" do
    setup do
      {:ok, spec} = Spec.new("acme/jon/triage", %{"team" => "acme"})
      %{spec: spec}
    end

    test "finds the agent's own files at the root, and a shared tree's under shared/", %{
      spec: spec
    } do
      assert {:ok, %Mount{name: nil}, "notes/a.md"} = Spec.resolve(spec, "notes/a.md")

      assert {:ok, %Mount{name: "team"}, "findings/a.md"} =
               Spec.resolve(spec, "shared/team/findings/a.md")
    end

    test "names the trees it shares where a path names another", %{spec: spec} do
      assert Spec.resolve(spec, "shared/other/a.md") ==
               {:error,
                "No tree is shared with you as shared/other; the trees shared with you are shared/team"}

      assert {:error, _message} = Spec.resolve(spec, "shared/team")
      assert {:error, _message} = Spec.resolve(spec, "/etc/passwd")
    end
  end

  describe "context/2" do
    setup do
      {:ok, spec} = Spec.new("acme/jon/triage", %{"team" => "acme"})
      {:ok, spec: spec}
    end

    test "names files in the agent's own tree and the trees it shares, once each, as written",
         %{spec: spec} do
      assert {:ok, %Spec{context: context}} =
               Spec.context(spec, ["./SOUL.md", "shared/team//CONVENTIONS.md", "SOUL.md"])

      assert context == ["SOUL.md", "shared/team/CONVENTIONS.md"]
    end

    test "refuses a path no file of the workspace is at", %{spec: spec} do
      assert {:error, "context: ../other/MEMORY.md climbs out of the workspace with .."} =
               Spec.context(spec, ["../other/MEMORY.md"])

      assert {:error, "context: No tree is shared with you as shared/theirs" <> _rest} =
               Spec.context(spec, ["shared/theirs/x.md"])

      assert {:error, "context: 7 is not a path"} = Spec.context(spec, [7])
    end

    test "is a list of at most twenty files", %{spec: spec} do
      assert {:error, "context is a list of files"} = Spec.context(spec, "SOUL.md")

      assert {:error, "context names at most 20 files"} =
               Spec.context(spec, Enum.map(1..21, &"#{&1}.md"))
    end
  end
end
