defmodule WardrikACP.ScratchTest do
  use WardrikACP.Case, async: true

  @scratch %{checkout: nil}

  test "works without a checkout in a scratch directory of its own", %{acp: acp} do
    {:ok, output, _context} = call(acp, [write("notes.txt"), %{"say" => "Done."}], @scratch)

    assert %{"message" => "Done.", "stop_reason" => "end_turn", "directory" => directory} =
             output

    refute Map.has_key?(output, "branch")
    assert directory =~ "/peer/.scratch/agent-one/_/fix"
    notes = Path.join(directory, "notes.txt")
    assert File.read!(notes) == "Some work."
  end

  test "continues the same session and directory for the same work", %{acp: acp, log: log} do
    {:ok, first, _context} = call(acp, [], @scratch)
    {:ok, second, _context} = call(acp, [], @scratch)

    assert first["directory"] == second["directory"]
    assert [_session] = find_sent(log, "session/new")
  end

  test "offers checkout only when there are checkouts", context do
    tool = tool(context.acp)
    assert tool.schema["required"] == ["task", "work"]
    assert tool.schema["properties"]["checkout"]["enum"] == ["repo"]

    bare = start_acp(context, [])
    tool = tool(bare)
    assert tool.schema["required"] == ["task", "work"]
    refute Map.has_key?(tool.schema["properties"], "checkout")

    assert {:error, "No checkout named repo. Leave checkout out."} = call(bare, [])
    assert {:ok, %{"directory" => _directory}, _context} = call(bare, [], @scratch)
  end

  test "sweeps a scratch directory after it goes unused", context do
    acp = start_acp(context, [repo: context.repo], scratch: :timer.seconds(30))
    {:ok, old, _context} = call(acp, [write("a.txt")], Map.put(@scratch, :work, "old"))

    assert {:park, :ask} =
             call(acp, [ask("edit", %{"path" => "d"})], %{
               checkout: nil,
               work: "waiting",
               gate: [ask: ["peer__edit"]]
             })

    {:ok, recent, _context} = call(acp, [], Map.put(@scratch, :work, "recent"))

    parent = Path.dirname(old["directory"])
    waiting = Path.join(parent, "waiting")
    a_minute_ago = System.os_time(:second) - 60
    for path <- [old["directory"], waiting], do: File.touch!(path, a_minute_ago)

    assert WardrikACP.sweep(acp) == [old["directory"]]
    refute File.exists?(old["directory"])
    assert File.dir?(waiting)
    assert File.dir?(recent["directory"])
  end

  defp tool(acp) do
    context = context(acp, %{})
    [tool] = WardrikACP.tools(context, name: acp, harnesses: :peer)
    tool
  end
end
