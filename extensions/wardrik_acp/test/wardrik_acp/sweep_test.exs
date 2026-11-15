defmodule WardrikACP.SweepTest do
  use WardrikACP.Case, async: true

  @tag gate: [ask: ["peer__edit"]]
  test "sweeps the worktrees whose work is in the base, and keeps the rest", context do
    %{acp: acp, repo: repo} = context
    worked = fn work, steps -> call(acp, steps, Map.put(context, :work, work)) end

    {:ok, merged, _context} = worked.("merged", [write("a.txt"), %{"commit" => "A"}])
    {:ok, open, _context} = worked.("open", [write("b.txt"), %{"commit" => "B"}])
    {:ok, dirty, _context} = worked.("dirty", [write("c.txt")])
    assert {:park, :ask} = worked.("waiting", [ask("edit", %{"path" => "d"})])
    {:ok, idle, _context} = worked.("idle", [])
    running = hang(acp, %{work: "running"})

    git(context, repo, ["merge", "--squash", "-q", merged["branch"]])
    git(context, repo, ["commit", "-q", "-m", "Squashed A"])

    swept = WardrikACP.sweep(acp)
    assert Enum.sort(swept) == Enum.sort([merged["worktree"], idle["worktree"]])

    refute File.exists?(merged["worktree"])
    refute File.exists?(merged["worktree"] <> ".json")
    assert git(context, repo, ["branch", "--list", merged["branch"]]) == ""

    for kept <- [open, dirty], do: assert(File.dir?(kept["worktree"]))

    worktrees = Path.dirname(merged["worktree"])

    for work <- ["waiting", "running"] do
      path = Path.join(worktrees, work)
      assert File.dir?(path)
    end

    Task.shutdown(running, :brutal_kill)
  end

  test "sweeps when it starts", context do
    test = self()

    handler = fn _name, measured, metadata, _config ->
      send(test, {:swept, metadata.acp, measured})
    end

    :telemetry.attach("sweep-#{context.test}", [:wardrik_acp, :sweep], handler, nil)

    acp = start_acp(context, [repo: context.repo], sweep: :timer.hours(1))

    assert_receive {:swept, ^acp, %{removed: 0}}, 5_000
    :telemetry.detach("sweep-#{context.test}")
  end
end
