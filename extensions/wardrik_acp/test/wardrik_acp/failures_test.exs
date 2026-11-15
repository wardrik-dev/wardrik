defmodule WardrikACP.FailuresTest do
  use WardrikACP.Case, async: true

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
end
