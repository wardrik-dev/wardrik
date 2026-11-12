defmodule WardrikWorkspaceTest do
  use ExUnit.Case, async: true

  alias WardrikCore.Tool
  alias WardrikWorkspace.Mount

  setup context do
    store = WardrikStore.ETS.new(name: :"store #{context.test}")
    start_supervised!({WardrikStore, store})

    opts = [
      store: store,
      tree: "agents/acme/agent/triage",
      shared: [
        %Mount{name: "team", tree: "shared/acme"},
        %Mount{name: "runbooks", tree: "shared/acme/runbooks", mode: :read}
      ]
    ]

    tools = Map.new(WardrikWorkspace.tools(nil, opts), &{&1.name, &1})

    %{
      store: store,
      opts: opts,
      tools: tools,
      agent: WardrikCore.Context.new(agent_id: "acme/triage")
    }
  end

  defp call(%{tools: tools, agent: agent}, name, args) do
    case Map.fetch!(tools, name).run.(args, agent) do
      {:ok, %ReqLLM.ToolResult{output: answer}} -> answer
      {:ok, answer} -> answer
    end
  end

  defp error(answer), do: answer.error.code

  test "writes a file, reads it numbered, and replaces it only over the version read", context do
    assert %{ok: true, version: v1} =
             call(context, "write_file", %{path: "./notes//today.md", content: "one\ntwo"})

    assert %{ok: true, content: "1\tone\n2\ttwo", version: ^v1, lines: 2, next_offset: nil} =
             call(context, "read_file", %{path: "notes/today.md"})

    assert error(call(context, "write_file", %{path: "notes/today.md", content: "x"})) == :exists

    assert %{ok: true, version: v2} =
             call(context, "write_file", %{path: "notes/today.md", content: "three", version: v1})

    assert error(
             call(context, "write_file", %{path: "notes/today.md", content: "x", version: v1})
           ) == :conflict

    assert error(
             call(context, "write_file", %{
               path: "notes/today.md",
               content: "x",
               version: "garbage"
             })
           ) == :conflict

    assert v2 != v1
  end

  test "reads a window of lines, and says where the rest begins", context do
    call(context, "write_file", %{
      path: "log.md",
      content: Enum.map_join(1..10, "\n", &"line #{&1}")
    })

    assert %{content: "3\tline 3\n4\tline 4", next_offset: 5} =
             call(context, "read_file", %{path: "log.md", offset: 3, limit: 2})

    assert error(call(context, "read_file", %{path: "none.md"})) == :not_found
  end

  test "appends, creating the file where it's missing", context do
    call(context, "write_file", %{path: "log.md", content: "a\n", append: true})
    call(context, "write_file", %{path: "log.md", content: "b\n", append: true})
    assert %{content: "1\ta\n2\tb\n3\t"} = call(context, "read_file", %{path: "log.md"})
  end

  test "edits text that appears once, or everywhere", context do
    call(context, "write_file", %{path: "a.md", content: "cat cat dog"})

    assert error(call(context, "edit_file", %{path: "a.md", old: "cat", new: "cow"})) ==
             :ambiguous

    assert %{replaced: 1} = call(context, "edit_file", %{path: "a.md", old: "dog", new: "fox"})

    assert %{replaced: 2} =
             call(context, "edit_file", %{path: "a.md", old: "cat", new: "cow", all: true})

    assert %{content: "1\tcow cow fox"} = call(context, "read_file", %{path: "a.md"})
    assert error(call(context, "edit_file", %{path: "a.md", old: "emu", new: "x"})) == :not_found
    assert error(call(context, "edit_file", %{path: "a.md", old: "", new: "x"})) == :not_found
    assert error(call(context, "edit_file", %{path: "b.md", old: "x", new: "y"})) == :not_found
  end

  test "lists and finds files across its own tree and those shared with it", context do
    call(context, "write_file", %{path: "notes/a.md", content: "alpha\nbeta"})
    call(context, "write_file", %{path: "shared/team/plan.md", content: "beta plan"})
    call(context, "write_file", %{path: "b.txt", content: "gamma"})

    assert %{files: listed, more: 0} = call(context, "list_files", %{pattern: "**/*.md"})
    assert Enum.map(listed, & &1.path) |> Enum.sort() == ["notes/a.md", "shared/team/plan.md"]

    assert %{files: [%{by: "acme/triage", bytes: 5}]} =
             call(context, "list_files", %{pattern: "*.txt"})

    assert %{matches: matches} = call(context, "search_files", %{pattern: "^beta", context: 1})
    assert %{path: "notes/a.md", line: 2, text: "beta", around: ["1\talpha"]} in matches
    assert %{path: "shared/team/plan.md", line: 1, text: "beta plan", around: []} in matches

    assert %{matches: [_one]} =
             call(context, "search_files", %{pattern: "beta", glob: "shared/**"})

    assert error(call(context, "search_files", %{pattern: "("})) == :bad_pattern
  end

  test "a file keeps the labels of what its writers had read, and its readers carry them",
       context do
    outside = %{context | agent: labelled(context.agent, ["outside"])}

    call(outside, "write_file", %{path: "notes/page.md", content: "From the web."})
    call(context, "write_file", %{path: "notes/mine.md", content: "Mine."})

    assert {:ok, %ReqLLM.ToolResult{output: %{ok: true}, metadata: %{labels: ["outside"]}}} =
             run(context, "read_file", %{path: "notes/page.md"})

    assert {:ok, %{ok: true}} = run(context, "read_file", %{path: "notes/mine.md"})

    call(context, "write_file", %{path: "notes/page.md", content: " More.", append: true})

    assert {:ok, %ReqLLM.ToolResult{metadata: %{labels: ["outside"]}}} =
             run(context, "read_file", %{path: "notes/page.md"})

    call(%{context | agent: labelled(context.agent, ["books"])}, "edit_file", %{
      path: "notes/mine.md",
      old: "Mine",
      new: "Ours"
    })

    assert {:ok, %ReqLLM.ToolResult{metadata: %{labels: ["books", "outside"]}}} =
             run(context, "search_files", %{pattern: "."})

    assert {:ok, %ReqLLM.ToolResult{metadata: %{labels: ["books", "outside"]}}} =
             run(context, "list_files", %{})
  end

  defp run(%{tools: tools, agent: agent}, name, args),
    do: Map.fetch!(tools, name).run.(args, agent)

  defp labelled(agent, labels),
    do: %{agent | messages: [ReqLLM.Context.user("Go.", %{labels: labels})]}

  test "deletes a file, and says whether it was there", context do
    call(context, "write_file", %{path: "a.md", content: "x"})
    assert %{deleted: true} = call(context, "delete_file", %{path: "a.md"})
    assert %{deleted: false} = call(context, "delete_file", %{path: "a.md"})
  end

  test "refuses a path that leaves the workspace, a tree not shared, and writing one it may only read",
       context do
    assert error(call(context, "read_file", %{path: "../x"})) == :bad_path
    assert error(call(context, "read_file", %{path: "/etc/passwd"})) == :bad_path
    assert error(call(context, "read_file", %{path: "~/x"})) == :bad_path
    assert error(call(context, "read_file", %{path: "a\\b"})) == :bad_path
    assert error(call(context, "read_file", %{path: "."})) == :bad_path
    assert error(call(context, "read_file", %{path: String.duplicate("a", 1025)})) == :bad_path
    assert error(call(context, "read_file", %{path: 1})) == :bad_path
    assert error(call(context, "read_file", %{path: "shared/other/x.md"})) == :bad_path

    assert error(call(context, "write_file", %{path: "shared/runbooks/x.md", content: "x"})) ==
             :read_only

    big = String.duplicate("x", 4 * 1024 * 1024 + 1)
    assert error(call(context, "write_file", %{path: "big.md", content: big})) == :too_large
  end

  test "says what each call acts on, for a policy to name", %{tools: tools} do
    assert Tool.annotation(tools["write_file"], :resources).(%{"path" => "notes/a.md"}) == [
             "notes/a.md"
           ]

    assert Tool.annotation(tools["list_files"], :resources).(%{}) == ["**"]

    assert Tool.annotation(tools["search_files"], :resources).(%{"glob" => "notes/*"}) == [
             "notes/*"
           ]

    assert Tool.annotation(tools["delete_file"], :resources).(%{}) == []
    assert Tool.annotation(tools["read_file"], :read_only)
  end
end
