defmodule WardrikACP.WorktreesTest do
  use WardrikACP.Case, async: true

  test "runs a task in a worktree of its own, and reports its commits", %{acp: acp} do
    {:ok, output, _context} = call(acp, [%{"say" => "Fixed."}, %{"commit" => "Fix login"}])

    assert %{
             "message" => "Fixed.",
             "stop_reason" => "end_turn",
             "branch" => "wardrik/agent-one/_/fix",
             "commits" => [%{"subject" => "Fix login"}],
             "refused" => []
           } = output

    assert File.dir?(output["worktree"])
  end

  test "continues the same session and branch for the same work", %{acp: acp, log: log} do
    {:ok, _output, _context} = call(acp, [%{"commit" => "One"}])
    {:ok, output, _context} = call(acp, [%{"commit" => "Two"}])

    assert [%{"subject" => "One"}, %{"subject" => "Two"}] = output["commits"]
    assert [_session] = find_sent(log, "session/new")
  end

  test "puts the instructions and context files before the first prompt", %{acp: acp, log: log} do
    {:ok, _output, _context} = call(acp, [])
    {:ok, _output, _context} = call(acp, [])

    assert [first, second] = find_sent(log, "session/prompt")
    assert [%{"text" => "Be brief.\n\nAGENTS.md:\n\nRun mix test."}, _task] = first["prompt"]
    assert [_task] = second["prompt"]
  end

  @tag peer: %{"PEER_SYSTEM" => "1"}
  test "sends the instructions as a system prompt when the agent takes one", %{acp: acp, log: log} do
    {:ok, _output, _context} = call(acp, [])

    assert [%{"systemPrompt" => %{"mode" => "append", "content" => [%{"text" => text}]}}] =
             find_sent(log, "session/new")

    assert text =~ "Be brief."
    assert [%{"prompt" => [_task]}] = find_sent(log, "session/prompt")
  end

  test "re-adds a removed worktree on its branch", %{acp: acp, repo: repo} do
    {:ok, output, _context} = call(acp, [%{"commit" => "One"}])
    stop_connection(acp)
    File.rm_rf!(output["worktree"])

    {_output, 0} =
      System.cmd("git", ["-C", repo, "worktree", "prune"], stderr_to_stdout: true)

    {:ok, output, _context} = call(acp, [%{"commit" => "Two"}])
    assert [%{"subject" => "One"}, %{"subject" => "Two"}] = output["commits"]
  end

  test "names the worktree after the work", %{acp: acp} do
    {:ok, output, _context} = call(acp, [], %{work: "!!"})
    assert output["branch"] == "wardrik/agent-one/_/_"
  end

  @tag harness: [command: "true"]
  test "refuses a checkout that isn't a git repository", %{acp: acp} do
    acp_dir =
      Path.join(System.tmp_dir!(), "wardrik_acp_plain_#{System.unique_integer([:positive])}")

    File.mkdir_p!(acp_dir)
    on_exit(fn -> File.rm_rf!(acp_dir) end)

    plain = Module.concat(acp, "Plain")

    start_supervised!(
      {WardrikACP,
       name: plain,
       worktrees: Path.join(acp_dir, "worktrees"),
       checkouts: [repo: acp_dir],
       harnesses: [peer: [command: "true"]]},
      id: plain
    )

    assert {:error, message} = call(plain, [])
    assert message == "#{acp_dir} isn't a git repository with a commit."
  end

  test "starts new work from the checkout's base", %{repo: repo} = context do
    git(context, repo, ["branch", "release"])
    git(context, repo, ["commit", "-q", "--allow-empty", "-m", "Second"])
    acp = start_acp(context, repo: [path: repo, base: "release"])

    {:ok, output, _context} = call(acp, [%{"commit" => "One"}])

    assert [%{"subject" => "One"}] = output["commits"]

    assert git(context, repo, ["rev-parse", output["head"] <> "^"]) ==
             git(context, repo, ["rev-parse", "release"])
  end

  test "fetches the base before new work starts", %{repo: repo, dir: dir} = context do
    origin = Path.join(dir, "origin.git")
    clone = Path.join(dir, "clone")
    git(context, dir, ["clone", "-q", "--bare", repo, origin])
    git(context, dir, ["clone", "-q", origin, clone])
    git(context, repo, ["commit", "-q", "--allow-empty", "-m", "Upstream"])
    git(context, repo, ["push", "-q", origin, "main"])
    acp = start_acp(context, clone: [path: clone, base: "origin/main", fetch: true])

    {:ok, output, _context} = call(acp, [%{"commit" => "One"}], %{checkout: "clone"})

    assert [%{"subject" => "One"}] = output["commits"]
    assert git(context, clone, ["log", "-1", "--format=%s", output["head"] <> "^"]) == "Upstream"
  end
end
