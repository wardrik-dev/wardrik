defmodule WardrikACPTest do
  use ExUnit.Case, async: true

  alias Wardrik.Context
  alias Wardrik.Resume
  alias Wardrik.ToolCall
  alias WardrikACP.Connection
  alias WardrikACP.TestGate, as: Gate

  @peer Path.expand("support/peer.exs", __DIR__)

  setup tags do
    dir = Path.join(System.tmp_dir!(), "wardrik_acp_#{System.unique_integer([:positive])}")
    repo = Path.join(dir, "repo")
    gitconfig = Path.join(dir, "gitconfig")
    log = Path.join(dir, "peer.log")
    File.mkdir_p!(repo)
    on_exit(fn -> File.rm_rf!(dir) end)

    # The tests' commits use a config of their own, not the config of whoever runs them.
    File.write!(gitconfig, "[user]\n\tname = Test\n\temail = test@example.com\n")
    git = %{"GIT_CONFIG_GLOBAL" => gitconfig, "GIT_CONFIG_NOSYSTEM" => "1"}

    agents_file = Path.join(repo, "AGENTS.md")

    for args <- [["init", "-q", "-b", "main"], ["add", "."], ["commit", "-q", "-m", "First"]] do
      if args == ["add", "."], do: File.write!(agents_file, "Run mix test.")
      {_output, 0} = System.cmd("git", ["-C", repo | args], env: git, stderr_to_stdout: true)
    end

    env =
      git
      |> Map.put("PEER_LOG", log)
      |> Map.merge(tags[:peer] || %{})

    harness =
      Keyword.merge(
        [
          command: "elixir",
          args: [@peer],
          env: env,
          instructions: "Be brief.",
          context: ["AGENTS.md", "MISSING.md"]
        ],
        tags[:harness] || []
      )

    context = %{log: log, repo: repo, dir: dir, git: git, harness: harness}
    Map.put(context, :acp, start_acp(context, repo: repo))
  end

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
    assert [_session] = sent(log, "session/new")
  end

  test "puts the instructions and context files before the first prompt", %{acp: acp, log: log} do
    {:ok, _output, _context} = call(acp, [])
    {:ok, _output, _context} = call(acp, [])

    assert [first, second] = sent(log, "session/prompt")
    assert [%{"text" => "Be brief.\n\nAGENTS.md:\n\nRun mix test."}, _task] = first["prompt"]
    assert [_task] = second["prompt"]
  end

  @tag peer: %{"PEER_SYSTEM" => "1"}
  test "sends the instructions as a system prompt when the agent takes one", %{acp: acp, log: log} do
    {:ok, _output, _context} = call(acp, [])

    assert [%{"systemPrompt" => %{"mode" => "append", "content" => [%{"text" => text}]}}] =
             sent(log, "session/new")

    assert text =~ "Be brief."
    assert [%{"prompt" => [_task]}] = sent(log, "session/prompt")
  end

  test "sends each permission request through the middleware as a tool call", %{acp: acp} do
    {:ok, output, _context} = call(acp, [ask("execute", %{"command" => "mix test"})])

    assert_received {:decided, %ToolCall{id: "call-1:p0", name: "peer__execute", arguments: args},
                     [], annotations}

    assert args == %{"command" => "mix test"}
    assert %{gated: true, read_only: false} = annotations
    assert annotations.resources.(args) == ["lib/app.ex", "/elsewhere/app.ex"]
    assert output["message"] == "allowed Run it"
  end

  @tag gate: [deny: ["peer__execute"]]
  test "refuses a request the middleware refuses", %{acp: acp} = tags do
    {:ok, output, _context} = call(acp, [ask("execute", %{"command" => "rm -rf /"})], tags)

    assert output["message"] == "refused Run it"
    assert output["refused"] == [%{"title" => "Run it", "reason" => "Denied."}]
  end

  @tag gate: [ask: ["peer__edit"]]
  test "parks on a request, and answers it when the call resumes", %{acp: acp} = tags do
    steps = [ask("edit", %{"path" => "a"}), ask("edit", %{"path" => "b"})]

    assert {:park, :ask} = call(acp, steps, tags)
    assert {:park, :ask} = call(acp, steps, Map.put(tags, :resume, approve()))

    {:ok, output, _context} = call(acp, steps, Map.put(tags, :resume, approve()))
    assert output["message"] == "allowed Run it"
  end

  @tag gate: [ask: ["peer__edit"]], peer: %{"PEER_LOAD" => "1"}
  test "restores a session whose process stopped while it was parked",
       %{acp: acp, log: log} = tags do
    steps = [ask("edit", %{"path" => "a"})]
    assert {:park, :ask} = call(acp, steps, tags)

    stop_connection(acp)
    {:ok, output, _context} = call(acp, steps, Map.put(tags, :resume, approve()))

    assert output["message"] =~ "received: A person approved this: Run it."
    assert [_load] = sent(log, "session/load")
  end

  @tag gate: [ask: ["peer__edit"]]
  test "tells the agent what a person refused, once its process stopped", %{acp: acp} = tags do
    assert {:park, :ask} = call(acp, [ask("edit", %{"path" => "a"})], tags)

    stop_connection(acp)
    refuse = %Resume{reason: :ask, input: %{"call-1" => {:deny, "Not that file."}}}
    {:ok, output, _context} = call(acp, [], Map.put(tags, :resume, refuse))

    assert output["message"] =~ "received: A person refused this: Run it. Not that file."
  end

  test "carries on after a restart left the call in doubt", %{acp: acp} = tags do
    in_doubt = %Resume{reason: :in_doubt, input: %{"call-1" => :approve}}
    {:ok, output, _context} = call(acp, [], Map.put(tags, :resume, in_doubt))

    assert output["message"] =~ "received: Wardrik restarted while you worked on this task."
    refute_received {:decided, _call, _labels, _annotations}
  end

  test "measures what each call adds to the session's cost", %{acp: acp} do
    {:ok, _output, context} = call(acp, [%{"cost" => 0.25}, %{"cost" => 0.75}])
    assert context.measurements.usd == 0.75

    {:ok, _output, context} = call(acp, [%{"cost" => 1.0}])
    assert context.measurements.usd == 0.25
  end

  test "labels what follows a fetch as outside", %{acp: acp} do
    steps = [%{"tool" => %{"kind" => "fetch", "title" => "Read a page"}}, ask("execute", %{})]
    {:ok, %ReqLLM.ToolResult{output: output, metadata: metadata}, _context} = call(acp, steps)

    assert_received {:decided, %ToolCall{name: "peer__execute"}, ["outside"], _annotations}
    assert metadata.labels == ["outside"]
    assert output["message"] == "allowed Run it"
  end

  test "emits each session update", %{acp: acp} do
    test = self()
    handler = fn name, _measured, metadata, _config -> send(test, {name, metadata.update}) end
    :telemetry.attach("update-#{inspect(acp)}", [:wardrik_acp, :update], handler, nil)

    {:ok, _output, _context} = call(acp, [%{"say" => "Hello."}])

    assert_received {[:wardrik_acp, :update],
                     %{
                       "sessionUpdate" => "agent_message_chunk",
                       "content" => %{"text" => "Hello."}
                     }}
  end

  @tag harness: [meta: %{"claudeCode" => %{"options" => %{"settingSources" => []}}}]
  test "sends meta when a session starts", %{acp: acp, log: log} do
    {:ok, _output, _context} = call(acp, [])

    assert [%{"_meta" => %{"claudeCode" => %{"options" => %{"settingSources" => []}}}}] =
             sent(log, "session/new")
  end

  @tag harness: [options: %{"mode" => "ask"}]
  test "sets config options by category", %{acp: acp, log: log} do
    {:ok, _output, _context} = call(acp, [])
    assert [%{"configId" => "mode", "value" => "ask"}] = sent(log, "session/set_config_option")
  end

  @tag harness: [options: %{"model" => "opus"}]
  test "refuses a config option the agent doesn't offer", %{acp: acp} do
    assert {:error, "peer has no config option model. It has: mode."} = call(acp, [])
  end

  @tag harness: [command: "no-such-acp-agent"]
  test "says when the command isn't installed", %{acp: acp} do
    assert {:error, "no-such-acp-agent isn't installed or isn't on PATH."} = call(acp, [])
  end

  test "refuses a checkout it wasn't given", %{acp: acp} do
    context = context(acp, %{})
    [tool] = WardrikACP.tools(context, name: acp, harnesses: :peer, checkouts: [])
    args = %{"task" => "Go.", "checkout" => "repo", "work" => "fix"}

    assert {:error, "No checkout named repo. Use one of: ."} = tool.run.(args, context)
  end

  test "reports an agent that exits while it works", %{acp: acp} do
    assert {:error, "peer failed: peer exited with status 3."} = call(acp, [%{"exit" => 3}])
  end

  test "cancels the prompt of a call that was stopped", %{acp: acp, log: log} do
    acp
    |> hang()
    |> Task.shutdown(:brutal_kill)

    {:ok, output, _context} = call(acp, [%{"say" => "Done."}])
    assert output["message"] == "Done."
    assert [_cancel] = sent(log, "session/cancel")
  end

  @tag gate: [ask: ["peer__edit"]], peer: %{"PEER_LOAD" => "1"}
  test "allows the restored request once when the agent asks for it again", %{acp: acp} = tags do
    steps = [ask("edit", %{"path" => "a"}), ask("edit", %{"path" => "b"})]
    assert {:park, :ask} = call(acp, steps, tags)

    stop_connection(acp)
    assert {:park, :ask} = call(acp, steps, Map.put(tags, :resume, approve()))

    # "a" parks, is answered once restored, and is allowed when asked again. "b" parks.
    assert decided_paths() == ["a", "a", "b"]
  end

  @tag gate: [ask: ["peer__edit"]], peer: %{"PEER_RESUME" => "1"}
  test "resumes a session when the agent can't load one", %{acp: acp, log: log} = tags do
    assert {:park, :ask} = call(acp, [ask("edit", %{"path" => "a"})], tags)

    stop_connection(acp)
    {:ok, _output, _context} = call(acp, [], Map.put(tags, :resume, approve()))

    assert [_resume] = sent(log, "session/resume")
  end

  @tag gate: [ask: ["peer__edit"]], peer: %{"PEER_LOAD" => "fail"}
  test "starts a new session when the old one won't load", %{acp: acp, log: log} = tags do
    assert {:park, :ask} = call(acp, [ask("edit", %{"path" => "a"})], tags)

    stop_connection(acp)
    {:ok, output, _context} = call(acp, [], Map.put(tags, :resume, approve()))

    assert output["message"] =~ "A person approved this"
    assert [_first, _second] = sent(log, "session/new")
  end

  @tag gate: [ask: ["peer__edit"]]
  test "parks again when the resumed call has no answer for it", %{acp: acp} = tags do
    assert {:park, :ask} = call(acp, [ask("edit", %{"path" => "a"})], tags)

    stop_connection(acp)
    unanswered = %Resume{reason: :ask, input: %{}}
    assert {:park, :ask} = call(acp, [], Map.put(tags, :resume, unanswered))
  end

  test "carries on when a resumed call has nothing waiting", %{acp: acp} = tags do
    {:ok, output, _context} = call(acp, [], Map.put(tags, :resume, approve()))
    assert output["message"] =~ "received: Carry on with the task:"
  end

  test "passes input that isn't an object as input", %{acp: acp} do
    {:ok, _output, _context} =
      call(acp, [
        %{"ask" => %{"kind" => "execute", "title" => "Run it", "rawInput" => "ls"}},
        %{"ask" => %{"kind" => "other", "title" => "Do it"}}
      ])

    assert_received {:decided, %ToolCall{name: "peer__execute", arguments: %{"input" => "ls"}},
                     _labels, _annotations}

    assert_received {:decided, %ToolCall{name: "peer__other", arguments: %{}}, _labels,
                     %{resources: resources}}

    assert resources.(%{}) == []
  end

  test "answers a request it doesn't serve with an error", %{acp: acp} do
    {:ok, output, _context} = call(acp, [%{"request" => "fs/read_text_file"}])
    assert output["message"] == "Method not found: fs/read_text_file"
  end

  test "reports a prompt the agent fails", %{acp: acp} do
    assert {:error, "peer failed: Out of credits."} = call(acp, [%{"fail" => "Out of credits."}])
  end

  test "reports a cancelled prompt", %{acp: acp} do
    assert {:error, "peer was cancelled."} = call(acp, [%{"stop" => "cancelled"}])
  end

  test "keeps what it said after a tool it ran", %{acp: acp} do
    steps = [
      %{"say" => "Looking."},
      %{"tool" => %{"kind" => "read", "title" => "Read"}},
      %{"say" => "Done."}
    ]

    {:ok, output, _context} = call(acp, steps)
    assert output["message"] == "Done."
  end

  @tag harness: [options: %{"mode" => true}]
  test "sets a boolean config option", %{acp: acp, log: log} do
    {:ok, _output, _context} = call(acp, [])
    assert [%{"type" => "boolean", "value" => true}] = sent(log, "session/set_config_option")
  end

  @tag harness: [idle: 1]
  test "stops the agent once no call uses it", %{acp: acp} do
    {:ok, _output, _context} = call(acp, [])
    supervisor = Connection.supervisor(acp)
    [{_id, pid, _type, _modules}] = DynamicSupervisor.which_children(supervisor)
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
  end

  test "refuses a second call on work that's running", %{acp: acp} do
    task = hang(acp)
    assert {:error, "peer is already working on this. Use another work name."} = call(acp, [])
    Task.shutdown(task, :brutal_kill)
  end

  test "reports an agent stopped while it works", %{acp: acp} do
    task = hang(acp)
    supervisor = Connection.supervisor(acp)
    [{_id, pid, _type, _modules}] = DynamicSupervisor.which_children(supervisor)
    :ok = DynamicSupervisor.terminate_child(supervisor, pid)

    assert {:error, "peer stopped: :shutdown"} = Task.await(task)
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
    handler = fn _name, measured, _metadata, _config -> send(test, {:swept, measured}) end
    :telemetry.attach("sweep-#{context.test}", [:wardrik_acp, :sweep], handler, nil)

    start_acp(context, [repo: context.repo], sweep: :timer.hours(1))

    assert_receive {:swept, %{removed: 0}}, 5_000
    :telemetry.detach("sweep-#{context.test}")
  end

  defp write(path), do: %{"write" => %{"path" => path, "text" => "Some work."}}

  defp start_acp(context, checkouts, opts \\ []) do
    acp = Module.concat(__MODULE__, "ACP#{System.unique_integer([:positive])}")

    start_supervised!(
      {WardrikACP,
       Keyword.merge(
         [
           name: acp,
           worktrees: Path.join(context.dir, "worktrees"),
           checkouts: checkouts,
           harnesses: [peer: context.harness],
           sweep: :infinity
         ],
         opts
       )},
      id: acp
    )

    acp
  end

  defp git(context, dir, args) do
    {output, 0} = System.cmd("git", ["-C", dir | args], env: context.git, stderr_to_stdout: true)
    String.trim(output)
  end

  defp call(acp, steps, tags \\ %{}) do
    args = %{
      "task" => JSON.encode!(steps),
      "checkout" => tags[:checkout] || "repo",
      "work" => tags[:work] || "fix"
    }

    context = context(acp, tags)
    [tool] = WardrikACP.tools(context, name: acp, harnesses: :peer)
    tool.run.(args, context)
  end

  defp context(_acp, tags) do
    Context.new(
      agent_id: "agent/one",
      step: {:tool_call, %ToolCall{id: "call-1", name: "peer"}},
      middleware: [{Gate, [test: self()] ++ (tags[:gate] || [])}],
      resume: tags[:resume]
    )
  end

  defp ask(kind, input),
    do: %{
      "ask" => %{
        "kind" => kind,
        "title" => "Run it",
        "rawInput" => input,
        "locations" => [%{"path" => "$CWD/lib/app.ex"}, %{"path" => "/elsewhere/app.ex"}]
      }
    }

  defp hang(acp, tags \\ %{}) do
    test = self()
    handler = "hang-#{inspect(make_ref())}"
    working = fn _name, _measured, _metadata, _config -> send(test, :working) end
    :telemetry.attach(handler, [:wardrik_acp, :update], working, nil)

    task = Task.async(fn -> call(acp, [%{"say" => "Working."}, %{"hang" => true}], tags) end)
    assert_receive :working, 5_000
    :telemetry.detach(handler)
    task
  end

  defp decided_paths do
    receive do
      {:decided, %ToolCall{arguments: %{"path" => path}}, _labels, _annotations} ->
        [path | decided_paths()]
    after
      0 -> []
    end
  end

  defp approve, do: %Resume{reason: :ask, input: %{"call-1" => :approve}}

  defp stop_connection(acp) do
    supervisor = Connection.supervisor(acp)
    [_one] = DynamicSupervisor.which_children(supervisor)
    stop_connections(acp)
  end

  defp stop_connections(acp) do
    supervisor = Connection.supervisor(acp)

    for {_id, pid, _type, _modules} <- DynamicSupervisor.which_children(supervisor) do
      ref = Process.monitor(pid)
      :ok = DynamicSupervisor.terminate_child(supervisor, pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}
    end
  end

  defp sent(log, method) do
    lines =
      log
      |> File.read!()
      |> String.split("\n", trim: true)

    for line <- lines,
        %{"method" => ^method} = message <- [JSON.decode!(line)],
        do: message["params"]
  end
end
