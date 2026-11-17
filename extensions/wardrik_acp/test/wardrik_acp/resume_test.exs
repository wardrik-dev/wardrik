defmodule WardrikACP.ResumeTest do
  use WardrikACP.Case, async: true

  @tag gate: [ask: ["peer__edit"]], peer: %{"PEER_LOAD" => "1"}
  test "allows the restored request once when the agent asks for it again", %{acp: acp} = tags do
    steps = [ask("edit", %{"path" => "a"}), ask("edit", %{"path" => "b"})]
    assert {:park, :ask} = call(acp, steps, tags)

    stop_connection(acp)
    assert {:park, :ask} = call(acp, steps, Map.put(tags, :resume, approve()))

    # "a" parks, is answered once restored, and is allowed when asked again. "b" parks.
    assert list_decided_paths() == ["a", "a", "b"]
  end

  @tag gate: [ask: ["peer__edit"]], peer: %{"PEER_RESUME" => "1"}
  test "resumes a session when the agent can't load one", %{acp: acp, log: log} = tags do
    assert {:park, :ask} = call(acp, [ask("edit", %{"path" => "a"})], tags)

    stop_connection(acp)
    {:ok, _output, _context} = call(acp, [], Map.put(tags, :resume, approve()))

    assert [_resume] = find_sent(log, "session/resume")
  end

  @tag gate: [ask: ["peer__edit"]], peer: %{"PEER_LOAD" => "fail"}
  test "starts a new session when the old one won't load", %{acp: acp, log: log} = tags do
    assert {:park, :ask} = call(acp, [ask("edit", %{"path" => "a"})], tags)

    stop_connection(acp)
    {:ok, output, _context} = call(acp, [], Map.put(tags, :resume, approve()))

    assert output["message"] =~ "A person approved this"
    assert [_first, _second] = find_sent(log, "session/new")
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
end
