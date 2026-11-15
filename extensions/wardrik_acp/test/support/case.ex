defmodule WardrikACP.Case do
  @moduledoc """
  Starts a `WardrikACP` for each test, with a git repository and a harness that runs
  `WardrikACP.TestPeer` in a VM of its own. Each test module runs its tests one at a time, as each starts a VM for
  the peer, so tests are split across modules to run side by side.
  """

  use ExUnit.CaseTemplate

  import ExUnit.Assertions
  import ExUnit.Callbacks

  alias Wardrik.Context
  alias Wardrik.Resume
  alias Wardrik.ToolCall
  alias WardrikACP.Connection
  alias WardrikACP.TestGate, as: Gate

  using do
    quote do
      import WardrikACP.Case

      alias Wardrik.Context
      alias Wardrik.Resume
      alias Wardrik.ToolCall
      alias WardrikACP.Connection
    end
  end

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
          args: [
            "-pa",
            Application.app_dir(:wardrik_acp, "ebin"),
            "-e",
            "WardrikACP.TestPeer.main()"
          ],
          env: env,
          instructions: "Be brief.",
          context: ["AGENTS.md", "MISSING.md"]
        ],
        tags[:harness] || []
      )

    context = %{log: log, repo: repo, dir: dir, git: git, harness: harness}
    Map.put(context, :acp, start_acp(context, repo: repo))
  end

  def write(path), do: %{"write" => %{"path" => path, "text" => "Some work."}}

  def start_acp(context, checkouts, opts \\ []) do
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

  def git(context, dir, args) do
    {output, 0} = System.cmd("git", ["-C", dir | args], env: context.git, stderr_to_stdout: true)
    String.trim(output)
  end

  def call(acp, steps, tags \\ %{}) do
    args = %{
      "task" => JSON.encode!(steps),
      "checkout" => tags[:checkout] || "repo",
      "work" => tags[:work] || "fix"
    }

    context = context(acp, tags)
    [tool] = WardrikACP.tools(context, name: acp, harnesses: :peer)
    tool.run.(args, context)
  end

  def context(_acp, tags) do
    Context.new(
      agent_id: "agent/one",
      step: {:tool_call, %ToolCall{id: "call-1", name: "peer"}},
      middleware: [{Gate, [test: self()] ++ (tags[:gate] || [])}],
      resume: tags[:resume],
      events: {WardrikACP.TestEvents, tags[:events] || self()}
    )
  end

  def ask(kind, input),
    do: %{
      "ask" => %{
        "kind" => kind,
        "title" => "Run it",
        "rawInput" => input,
        "locations" => [%{"path" => "$CWD/lib/app.ex"}, %{"path" => "/elsewhere/app.ex"}]
      }
    }

  def hang(acp, tags \\ %{}) do
    tags = Map.put(tags, :events, self())
    task = Task.async(fn -> call(acp, [%{"say" => "Working."}, %{"hang" => true}], tags) end)
    assert_receive {:event, %{name: [:wardrik_acp, :update]}}, 5_000
    task
  end

  def decided_paths do
    receive do
      {:decided, %ToolCall{arguments: %{"path" => path}}, _labels, _annotations} ->
        [path | decided_paths()]
    after
      0 -> []
    end
  end

  def approve, do: %Resume{reason: :ask, input: %{"call-1" => :approve}}

  def stop_connection(acp) do
    supervisor = Connection.supervisor(acp)
    [_one] = DynamicSupervisor.which_children(supervisor)
    stop_connections(acp)
  end

  def stop_connections(acp) do
    supervisor = Connection.supervisor(acp)

    for {_id, pid, _type, _modules} <- DynamicSupervisor.which_children(supervisor) do
      ref = Process.monitor(pid)
      :ok = DynamicSupervisor.terminate_child(supervisor, pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}
    end
  end

  def sent(log, method) do
    lines =
      log
      |> File.read!()
      |> String.split("\n", trim: true)

    for line <- lines,
        %{"method" => ^method} = message <- [JSON.decode!(line)],
        do: message["params"]
  end
end
