defmodule WardrikWorkspace.SpecTest do
  use ExUnit.Case, async: true

  alias Wardrik.AgentID.Prefix
  alias WardrikWorkspace.Mount
  alias WardrikWorkspace.Spec

  import Wardrik.AgentID, only: [sigil_A: 2]

  # A token reaching the agents under `prefix`.
  defp reaching(prefix),
    do: %Wardrik.Token{
      principal: Wardrik.Principal.new(:user, "jon"),
      scope: [Wardrik.Role.bind([:definer], prefix)]
    }

  describe "new/2" do
    test "gives an agent its own tree, and shares the trees its key reaches" do
      assert {:ok, spec} =
               Spec.new(Wardrik.AgentID.parse!("acme/triage"), %{
                 "team" => "acme",
                 "runbooks" => %{"tree" => "acme/runbooks", "mode" => "read"}
               })

      assert spec.tree == %Mount{tree: "agents/acme/triage"}

      assert spec.shared == [
               %Mount{name: "runbooks", tree: "shared/acme/runbooks", mode: :read},
               %Mount{name: "team", tree: "shared/acme"}
             ]

      assert {:ok, mine} =
               Spec.new(Wardrik.AgentID.parse!("acme/@jon/triage"), %{
                 "mine" => "acme/@jon/notes/"
               })

      assert mine.shared == [%Mount{name: "mine", tree: "shared/acme/@jon/notes"}]
    end

    test "refuses a user's agent its org's trees" do
      assert Spec.new(Wardrik.AgentID.parse!("acme/@jon/triage"), %{"team" => "acme"}) ==
               {:error, "shared team: acme belongs to acme/, which acme/@jon/triage is not under"}
    end

    test "refuses a tree under a scope the agent is not under" do
      assert Spec.new(Wardrik.AgentID.parse!("acme/@jon/triage"), %{"theirs" => "globex/findings"}) ==
               {:error,
                "shared theirs: globex/findings belongs to globex/, which acme/@jon/triage is not under"}

      assert {:error, _message} =
               Spec.new(Wardrik.AgentID.parse!("acme/@jon/triage"), %{"hers" => "acme/@ann/notes"})
    end

    test "refuses a name, a tree or a setting that does not read" do
      for {shared, said} <- [
            {%{"Team" => "acme"}, "is not a name"},
            {%{"team" => "acme/../x"}, "is not a tree"},
            {%{"team" => "acme/a/b/c"}, "is not a tree"},
            {%{"team" => "acme/jon/notes"}, "is not a tree"},
            {%{"team" => %{"tree" => "acme", "mode" => "rw"}}, "mode is read or write"},
            {%{"team" => %{"tree" => "acme", "size" => 1}}, "size is not a setting"},
            {%{"team" => 3}, "names a tree"}
          ] do
        assert {:error, message} = Spec.new(Wardrik.AgentID.parse!("acme/@jon/triage"), shared)
        assert message =~ said
      end
    end
  end

  describe "shares" do
    setup do
      {:ok, runbooks} =
        WardrikWorkspace.Share.new("acme/runbooks", read: ["acme/*"], write: ["acme/ops"])

      %{shares: [runbooks]}
    end

    test "let an agent mount a tree another owns, in the mode they let it", %{shares: shares} do
      read = %{"runbooks" => %{"tree" => "acme/runbooks", "mode" => "read"}}

      assert {:ok, %{shared: [%Mount{name: "runbooks", mode: :read}]}} =
               Spec.new(~A"acme/@jon/triage", read, shares: shares)

      assert Spec.new(~A"acme/@jon/triage", %{"runbooks" => "acme/runbooks"}, shares: shares) ==
               {:error,
                "shared runbooks: acme/runbooks is shared with acme/@jon/triage to read; " <>
                  "mount it with mode: read"}

      assert {:ok, %{shared: [%Mount{mode: :write}]}} =
               Spec.new(~A"acme/ops", %{"runbooks" => "acme/runbooks"}, shares: shares)

      assert {:error, _message} = Spec.new(~A"globex/triage", read, shares: shares)
      assert {:error, _message} = Spec.new(~A"acme/@jon/triage", read)
    end

    test "let a definition share what the deployment shares with its agent", %{shares: shares} do
      read = %{"runbooks" => %{"tree" => "acme/runbooks", "mode" => "read"}}
      {:ok, spec} = Spec.new(~A"acme/@jon/triage", read, shares: shares)
      jon = reaching(Prefix.new!(org: "acme", user: "jon"))

      assert Spec.within(spec, jon, id: ~A"acme/@jon/triage", shares: shares) == :ok
      assert {:error, _message} = Spec.within(spec, jon, id: ~A"acme/@jon/triage")
    end

    test "do not read where a tree or a prefix does not" do
      assert {:error, message} = WardrikWorkspace.Share.new("acme/a/b/c", read: ["acme/*"])
      assert message =~ "is not a tree"
      assert {:error, message} = WardrikWorkspace.Share.new("acme/runbooks", read: ["/nope"])
      assert message =~ "acme/runbooks read"
      assert {:error, _message} = WardrikWorkspace.Share.new("acme/runbooks", write: "acme/*")
    end
  end

  describe "within/3" do
    test "answers whether every tree shared belongs to agents a token reaches" do
      {:ok, spec} = Spec.new(~A"acme/triage", %{"team" => "acme"})
      triage = reaching(Prefix.of(~A"acme/triage"))

      assert Spec.within(spec, reaching(Prefix.new!(org: "acme")), id: ~A"acme/triage") == :ok
      assert Spec.within(spec, reaching(Prefix.all()), id: ~A"acme/triage") == :ok

      assert Spec.within(spec, triage, id: ~A"acme/triage") ==
               {:error, "shared team: acme belongs to acme/, which the token does not reach"}

      {:ok, jons} = Spec.new(~A"acme/@jon/triage", %{"notes" => "acme/@jon/notes"})
      jon = reaching(Prefix.new!(org: "acme", user: "jon"))

      assert Spec.within(jons, jon, id: ~A"acme/@jon/triage") == :ok

      assert Spec.within(jons, reaching(Prefix.new!(org: "acme")), id: ~A"acme/@jon/triage") ==
               {:error,
                "shared notes: acme/@jon/notes belongs to acme/@jon/, which the token does not reach"}

      {:ok, alone} = Spec.new(~A"acme/triage")
      assert Spec.within(alone, triage, id: ~A"acme/triage") == :ok
    end
  end

  describe "resolve/2" do
    setup do
      {:ok, spec} = Spec.new(Wardrik.AgentID.parse!("acme/triage"), %{"team" => "acme"})
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
      {:ok, spec} = Spec.new(Wardrik.AgentID.parse!("acme/triage"), %{"team" => "acme"})
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

    test "reads 16 KB of them into each turn unless context_bytes/2 says", %{spec: spec} do
      assert spec.context_bytes == 16 * 1024
      assert {:ok, %Spec{context_bytes: 65_536}} = Spec.context_bytes(spec, 65_536)

      for bytes <- [1023, 256 * 1024 + 1, "64KB", nil] do
        assert {:error, "context max_bytes is a number of bytes from 1024 to 262144"} =
                 Spec.context_bytes(spec, bytes)
      end
    end

    test "is a list of at most twenty files", %{spec: spec} do
      assert {:error, "context is a list of files"} = Spec.context(spec, "SOUL.md")

      assert {:error, "context names at most 20 files"} =
               Spec.context(spec, Enum.map(1..21, &"#{&1}.md"))
    end
  end
end
