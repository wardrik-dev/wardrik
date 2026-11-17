defmodule WardrikACP.RequestsTest do
  use WardrikACP.Case, async: true

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
    assert [_load] = find_sent(log, "session/load")
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
end
