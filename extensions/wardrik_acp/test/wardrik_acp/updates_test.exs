defmodule WardrikACP.UpdatesTest do
  use WardrikACP.Case, async: true

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
    {:ok, _output, _context} = call(acp, [%{"say" => "Hello."}])

    assert_received {:event,
                     %{
                       name: [:wardrik_acp, :update],
                       metadata: %{
                         update: %{
                           "sessionUpdate" => "agent_message_chunk",
                           "content" => %{"text" => "Hello."}
                         }
                       }
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

  @tag harness: [options: %{"mode" => true}]
  test "sets a boolean config option", %{acp: acp, log: log} do
    {:ok, _output, _context} = call(acp, [])
    assert [%{"type" => "boolean", "value" => true}] = sent(log, "session/set_config_option")
  end
end
