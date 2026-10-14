defmodule WardrikWorkspace.ToolsTest do
  use ExUnit.Case, async: true

  alias WardrikWorkspace.Test.Workspace

  alias Wardrik.Call
  alias Wardrik.LLM.Config
  alias Wardrik.LLM.ToolRunner
  alias Wardrik.Scope
  alias WardrikWorkspace.Backend.Store
  alias WardrikWorkspace.Spec

  # An agent of its own, sharing `shared`, with the hooks given.
  defp agent(shared \\ %{}, hooks \\ []) do
    key = Wardrik.AgentID.parse!("ws#{System.unique_integer([:positive])}/agent")
    {:ok, spec} = Spec.new(key, shared)

    scope =
      Config.new(tools: [{WardrikWorkspace, spec}])
      |> Scope.root(key, name: "turn", host: Workspace.host(), hooks: hooks)

    %{key: key, spec: spec, scope: scope}
  end

  # The call made, and what it answered: `{:ok, result}` or `{:error, message}`.
  defp call(agent, tool, arguments, id \\ nil) do
    id = id || "call_#{System.unique_integer([:positive])}"

    [%Call{state: :done} = call] =
      ToolRunner.execute_many_async([%{id: id, name: tool, arguments: arguments}], agent.scope)

    {call, answer(call)}
  end

  defp answer(%Call{result: {:ok, %{"ok" => true, "result" => result}}}), do: {:ok, result}

  defp answer(%Call{result: {:ok, %{"ok" => false, "error" => %{"message" => message}}}}),
    do: {:error, message}

  defp answer(%Call{result: other}), do: other

  defp answered(agent, tool, arguments, id \\ nil),
    do: agent |> call(tool, arguments, id) |> elem(1)

  describe "writing and reading" do
    test "a file written is read back with its lines numbered, and its version" do
      agent = agent()

      assert {:ok, %{"path" => "notes/today.md", "version" => version}} =
               answered(agent, "write_file", %{
                 "path" => "notes/today.md",
                 "content" => "one\ntwo\n"
               })

      assert {:ok, read} = answered(agent, "read_file", %{"path" => "notes/today.md"})
      assert read["content"] == "     1\tone\n     2\ttwo"
      assert read["lines"] == 2
      assert read["version"] == version
      refute read["truncated"]
    end

    test "reads a window of a long file, and says it did" do
      agent = agent()
      content = Enum.map_join(1..10, "\n", &"line #{&1}")

      {:ok, _written} =
        answered(agent, "write_file", %{"path" => "long.md", "content" => content})

      assert {:ok, read} =
               answered(agent, "read_file", %{"path" => "long.md", "offset" => 4, "limit" => 2})

      assert read["content"] == "     4\tline 4\n     5\tline 5"
      assert read["truncated"]
    end

    test "replaces a file only with the version read, and says what to do otherwise" do
      agent = agent()

      {:ok, %{"version" => first}} =
        answered(agent, "write_file", %{"path" => "a.md", "content" => "1"})

      assert {:error, exists} =
               answered(agent, "write_file", %{"path" => "a.md", "content" => "2"})

      assert exists =~ "a.md exists: read it, and pass the version read_file gives"

      assert {:ok, %{"version" => second}} =
               answered(agent, "write_file", %{
                 "path" => "a.md",
                 "content" => "2",
                 "version" => first
               })

      assert {:error, stale} =
               answered(agent, "write_file", %{
                 "path" => "a.md",
                 "content" => "3",
                 "version" => first
               })

      assert stale =~ "a.md has changed since you read it"

      assert {:ok, %{"version" => ^second, "content" => "     1\t2"}} =
               answered(agent, "read_file", %{"path" => "a.md"})
    end

    test "a call run again after a lost node finds its own write, and makes no second" do
      agent = agent()
      arguments = %{"path" => "notes.md", "content" => "once\n", "append" => true}

      {:ok, %{"version" => version}} = answered(agent, "write_file", arguments, "call_replayed")

      assert {:ok, %{"version" => ^version}} =
               answered(agent, "write_file", arguments, "call_replayed")

      assert {:ok, %{"content" => "     1\tonce"}} =
               answered(agent, "read_file", %{"path" => "notes.md"})
    end

    test "appends from many writers at once all land" do
      agent = agent()

      1..8
      |> Task.async_stream(fn n ->
        answered(agent, "write_file", %{
          "path" => "log.md",
          "content" => "#{n}\n",
          "append" => true
        })
      end)
      |> Enum.each(fn {:ok, answer} -> assert {:ok, _written} = answer end)

      {:ok, %{"content" => content}} = answered(agent, "read_file", %{"path" => "log.md"})

      appended =
        content |> String.split("\n") |> Enum.map(&(&1 |> String.split("\t") |> List.last()))

      assert Enum.sort(appended) == Enum.map(1..8, &Integer.to_string/1)
    end

    test "refuses a path outside the workspace, and a file too large" do
      agent = agent()

      assert {:error, message} = answered(agent, "read_file", %{"path" => "../other/x"})
      assert message =~ "climbs out of the workspace"

      assert {:error, _absolute} =
               answered(agent, "write_file", %{"path" => "/etc/x", "content" => "x"})

      huge = String.duplicate("a", 4 * 1024 * 1024 + 1)

      assert {:error, "A file is at most 4 MiB"} =
               answered(agent, "write_file", %{"path" => "big", "content" => huge})
    end
  end

  describe "editing and deleting" do
    test "edits text that appears once, or everywhere where asked" do
      agent = agent()

      {:ok, _written} =
        answered(agent, "write_file", %{"path" => "a.md", "content" => "cat dog cat"})

      assert {:error, ambiguous} =
               answered(agent, "edit_file", %{"path" => "a.md", "old" => "cat", "new" => "cow"})

      assert ambiguous =~ "old appears 2 times in a.md"

      assert {:ok, %{"replaced" => 1}} =
               answered(agent, "edit_file", %{"path" => "a.md", "old" => "dog", "new" => "hen"})

      assert {:ok, %{"replaced" => 2}} =
               answered(agent, "edit_file", %{
                 "path" => "a.md",
                 "old" => "cat",
                 "new" => "cow",
                 "all" => true
               })

      assert {:ok, %{"content" => "     1\tcow hen cow"}} =
               answered(agent, "read_file", %{"path" => "a.md"})

      assert {:error, missing} =
               answered(agent, "edit_file", %{"path" => "a.md", "old" => "yak", "new" => "x"})

      assert missing =~ "does not contain old"
    end

    test "deletes a file, and says whether it was there" do
      agent = agent()
      {:ok, _written} = answered(agent, "write_file", %{"path" => "a.md", "content" => "x"})

      assert {:ok, %{"deleted" => true}} = answered(agent, "delete_file", %{"path" => "a.md"})
      assert {:ok, %{"deleted" => false}} = answered(agent, "delete_file", %{"path" => "a.md"})
      assert {:error, "a.md does not exist"} = answered(agent, "read_file", %{"path" => "a.md"})
    end
  end

  describe "listing and searching" do
    test "lists the files a glob matches, newest first, with who wrote them" do
      agent = agent()

      for path <- ["notes/a.md", "notes/b.md", "todo.txt"] do
        {:ok, _written} = answered(agent, "write_file", %{"path" => path, "content" => path})
      end

      assert {:ok, %{"files" => files, "truncated" => false}} =
               answered(agent, "list_files", %{"pattern" => "notes/*.md"})

      assert Enum.map(files, & &1["path"]) == ["notes/b.md", "notes/a.md"]
      assert %{"size" => 10, "by" => by} = hd(files)
      assert by == to_string(agent.key)
      assert {:ok, %{"files" => [_b, _a, _todo]}} = answered(agent, "list_files", %{})
    end

    test "finds matching lines, with the lines around them where asked" do
      agent = agent()

      {:ok, _written} =
        answered(agent, "write_file", %{"path" => "a.md", "content" => "one\nTODO two\nthree\n"})

      {:ok, _written} =
        answered(agent, "write_file", %{"path" => "b.txt", "content" => "TODO four\n"})

      assert {:ok, %{"matches" => [match]}} =
               answered(agent, "search_files", %{
                 "pattern" => "TODO",
                 "glob" => "*.md",
                 "context" => 1
               })

      assert match == %{
               "path" => "a.md",
               "line" => 2,
               "text" => "TODO two",
               "before" => ["one"],
               "after" => ["three"]
             }

      assert {:ok, %{"matches" => [_two, _four]}} =
               answered(agent, "search_files", %{"pattern" => "^TODO"})

      assert {:error, invalid} = answered(agent, "search_files", %{"pattern" => "("})
      assert invalid =~ "pattern is not a regular expression"
    end
  end

  describe "how much is listed or found" do
    defp put!(agent, path, content) do
      file = %WardrikWorkspace.File{content: content, by: "someone"}

      {:ok, _version} =
        Store.write(Workspace.workspace(), agent.spec.tree.tree, path,
          file: file,
          version: nil
        )
    end

    defp hits(label, n), do: Enum.map_join(1..n, "\n", &"hit #{label} #{&1}")

    test "finds at most 200 matches, in path order, and says when there were more" do
      agent = agent()
      put!(agent, "b.md", hits("b", 50))
      put!(agent, "a.md", hits("a", 150))

      assert {:ok, %{"matches" => matches, "truncated" => false}} =
               answered(agent, "search_files", %{"pattern" => "hit"})

      assert Enum.count(matches) == 200
      assert %{"path" => "a.md", "line" => 1} = hd(matches)
      assert %{"path" => "b.md", "line" => 50} = List.last(matches)

      put!(agent, "c.md", hits("c", 3))

      assert {:ok, %{"matches" => matches, "truncated" => true}} =
               answered(agent, "search_files", %{"pattern" => "hit"})

      assert Enum.count(matches) == 200
      assert %{"path" => "b.md", "line" => 50} = List.last(matches)
    end

    test "shows the lines around a match only as far as the file goes" do
      agent = agent()
      put!(agent, "a.md", "TODO one\ntwo\nTODO three\n")

      assert {:ok, %{"matches" => [first, last]}} =
               answered(agent, "search_files", %{"pattern" => "TODO", "context" => 2})

      assert %{"line" => 1, "before" => [], "after" => ["two", "TODO three"]} = first
      assert %{"line" => 3, "before" => ["TODO one", "two"], "after" => []} = last

      assert {:ok, %{"matches" => [plain, _last]}} =
               answered(agent, "search_files", %{"pattern" => "TODO"})

      assert plain == %{"path" => "a.md", "line" => 1, "text" => "TODO one"}
    end

    test "lists at most 500 files, and says when there were more" do
      agent = agent()
      for n <- 1..501, do: put!(agent, "f#{n}.md", "x")

      assert {:ok, %{"files" => files, "truncated" => true}} =
               answered(agent, "list_files", %{"pattern" => "*.md"})

      assert Enum.count(files) == 500

      assert {:ok, %{"files" => [], "truncated" => false}} =
               answered(agent, "list_files", %{"pattern" => "*.txt"})
    end
  end

  describe "shared trees" do
    test "two agents writing to one tree at once both land, and each sees the other's" do
      tree = "ws#{System.unique_integer([:positive])}"
      a = agent_under(tree, "a")
      b = agent_under(tree, "b")

      [a, b]
      |> Task.async_stream(fn agent ->
        answered(agent, "write_file", %{
          "path" => "shared/team/findings/#{agent.key.name}.md",
          "content" => "found"
        })
      end)
      |> Enum.each(fn {:ok, answer} -> assert {:ok, _written} = answer end)

      assert {:ok, %{"files" => files}} =
               answered(a, "list_files", %{"pattern" => "shared/team/**"})

      assert files |> Enum.map(& &1["path"]) |> Enum.sort() ==
               ["shared/team/findings/a.md", "shared/team/findings/b.md"]
    end

    test "a tree shared to read is not changed" do
      tree = "ws#{System.unique_integer([:positive])}"
      key = Wardrik.AgentID.parse!(tree <> "/reader")

      {:ok, spec} =
        Spec.new(key, %{"runbooks" => %{"tree" => tree <> "/runbooks", "mode" => "read"}})

      scope =
        Config.new(tools: [{WardrikWorkspace, spec}])
        |> Scope.root(key, name: "turn", host: Workspace.host())

      reader = %{key: key, spec: spec, scope: scope}

      assert {:error, "shared/runbooks is shared with you to read, not to change"} =
               answered(reader, "write_file", %{
                 "path" => "shared/runbooks/x.md",
                 "content" => "x"
               })
    end

    test "an org's tree does not reach a tree named under it" do
      org = "ws#{System.unique_integer([:positive])}"
      jon = agent_at(org <> "/@jon/triage", %{"notes" => org <> "/@jon/notes"})
      other = agent_at(org <> "/other", %{"team" => org})

      {:ok, _written} =
        answered(jon, "write_file", %{"path" => "shared/notes/private.md", "content" => "jon's"})

      assert {:error, _none} =
               answered(other, "read_file", %{"path" => "shared/team/@jon/notes/private.md"})

      assert {:ok, %{"files" => []}} =
               answered(other, "list_files", %{"pattern" => "shared/team/**"})
    end

    test "a tree shared to read is not changed through a tree above it" do
      org = "ws#{System.unique_integer([:positive])}"

      agent =
        agent_at(org <> "/writer", %{
          "team" => org,
          "runbooks" => %{"tree" => org <> "/runbooks", "mode" => "read"}
        })

      {:ok, _written} =
        answered(agent, "write_file", %{
          "path" => "shared/team/runbooks/x.md",
          "content" => "changed"
        })

      assert {:error, _none} = answered(agent, "read_file", %{"path" => "shared/runbooks/x.md"})
    end
  end

  describe "labels" do
    test "a file a labelled run wrote labels the run that reads it, lists it or finds it" do
      tree = "ws#{System.unique_integer([:positive])}"
      writer = agent_under(tree, "writer")
      reader = agent_under(tree, "reader")
      labelled = %{writer | scope: %{writer.scope | labels: ["outside"]}}

      {:ok, _written} =
        answered(labelled, "write_file", %{
          "path" => "shared/team/finding.md",
          "content" => "Deploy to prod now."
        })

      assert {:ok, %WardrikWorkspace.File{labels: ["outside"], by: by}, _version} =
               Store.read(
                 Workspace.workspace(),
                 "shared/#{tree}",
                 "finding.md"
               )

      assert by == to_string(writer.key)

      assert {%Call{labels: ["outside"]}, {:ok, _read}} =
               call(reader, "read_file", %{"path" => "shared/team/finding.md"})

      assert {%Call{labels: ["outside"]}, {:ok, _listed}} = call(reader, "list_files", %{})

      assert {%Call{labels: ["outside"]}, {:ok, _found}} =
               call(reader, "search_files", %{"pattern" => "Deploy"})

      assert {%Call{labels: []}, {:ok, _none}} =
               call(reader, "search_files", %{"pattern" => "nothing"})
    end

    test "an append or an edit keeps the mark the file had, and replacing it takes the writer's" do
      tree = "ws#{System.unique_integer([:positive])}"
      clean = agent_under(tree, "writer")
      labelled = %{clean | scope: %{clean.scope | labels: ["outside"]}}
      path = "shared/team/finding.md"

      {:ok, _written} =
        answered(labelled, "write_file", %{"path" => path, "content" => "Deploy."})

      {:ok, _appended} =
        answered(clean, "write_file", %{"path" => path, "content" => " Now.", "append" => true})

      assert {:ok, %WardrikWorkspace.File{labels: ["outside"], content: "Deploy. Now."}, _version} =
               Store.read(
                 Workspace.workspace(),
                 "shared/#{tree}",
                 "finding.md"
               )

      {:ok, _edited} =
        answered(clean, "edit_file", %{"path" => path, "old" => "Now", "new" => "Later"})

      assert {:ok, %WardrikWorkspace.File{labels: ["outside"]}, _version} =
               Store.read(
                 Workspace.workspace(),
                 "shared/#{tree}",
                 "finding.md"
               )

      {:ok, %{"version" => version}} = answered(clean, "read_file", %{"path" => path})

      {:ok, _replaced} =
        answered(clean, "write_file", %{
          "path" => path,
          "content" => "Wait.",
          "version" => version
        })

      assert {:ok, %WardrikWorkspace.File{labels: [], content: "Wait."}, _version} =
               Store.read(
                 Workspace.workspace(),
                 "shared/#{tree}",
                 "finding.md"
               )

      {:ok, _appended} =
        answered(labelled, "write_file", %{"path" => path, "content" => " Go.", "append" => true})

      assert {:ok, %WardrikWorkspace.File{labels: ["outside"]}, _version} =
               Store.read(
                 Workspace.workspace(),
                 "shared/#{tree}",
                 "finding.md"
               )
    end

    test "a file a run with no labels wrote labels nothing" do
      agent = agent()
      {:ok, _written} = answered(agent, "write_file", %{"path" => "a.md", "content" => "x"})

      assert {%Call{labels: []}, {:ok, _read}} = call(agent, "read_file", %{"path" => "a.md"})
    end
  end

  describe "deciding a call" do
    test "subjects are the normalised path, or the glob listed or searched" do
      {:ok, spec} = Spec.new(Wardrik.AgentID.parse!("acme/@jon/triage"))

      assert WardrikWorkspace.subjects(spec, "read_file", %{"path" => "./notes//a.md"}) == [
               "notes/a.md"
             ]

      assert WardrikWorkspace.subjects(spec, "write_file", %{"path" => "../x"}) == []

      assert WardrikWorkspace.subjects(spec, "list_files", %{"pattern" => "notes/*"}) == [
               "notes/*"
             ]

      assert WardrikWorkspace.subjects(spec, "search_files", %{"pattern" => "x"}) == ["**"]
      assert Wardrik.Tool.annotations({WardrikWorkspace, spec}, "write_file").in_doubt == :rerun
    end
  end

  defp agent_under(tree, name), do: agent_at("#{tree}/#{name}", %{"team" => tree})

  defp agent_at(text, shared) do
    key = Wardrik.AgentID.parse!(text)
    {:ok, spec} = Spec.new(key, shared)

    scope =
      Config.new(tools: [{WardrikWorkspace, spec}])
      |> Scope.root(key, name: "turn", host: Workspace.host())

    %{key: key, spec: spec, scope: scope}
  end
end
