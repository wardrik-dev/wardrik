defmodule Wardrik.HTTP.MCPTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Wardrik.Test.HTTP

  @moduletag http: [mcp: true]

  setup :start_wardrik

  @version_key "io.modelcontextprotocol/protocolVersion"

  defp rpc(context, method, params \\ %{}, headers \\ []) do
    request(
      context,
      "POST",
      "/mcp",
      %{"jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => params},
      [{"accept", "application/json, text/event-stream"} | headers]
    )
  end

  defp call(context, name, arguments),
    do: rpc(context, "tools/call", %{"name" => name, "arguments" => arguments})

  test "agrees on a version, and says what it serves", context do
    conn = rpc(context, "initialize", %{"protocolVersion" => "2025-06-18", "capabilities" => %{}})

    assert %{
             "id" => 1,
             "result" => %{
               "protocolVersion" => "2025-06-18",
               "capabilities" => %{"tools" => %{}},
               "serverInfo" => %{"name" => "wardrik"}
             }
           } = body(conn)

    conn = rpc(context, "initialize", %{"protocolVersion" => "2099-01-01"})
    assert body(conn)["result"]["protocolVersion"] == "2025-11-25"
  end

  test "takes notifications without answering", context do
    conn =
      request(context, "POST", "/mcp", %{
        "jsonrpc" => "2.0",
        "method" => "notifications/initialized"
      })

    assert {conn.status, conn.resp_body} == {202, ""}
  end

  test "lists every operation people call, with its input and effect", context do
    tools = body(rpc(context, "tools/list"))["result"]["tools"]
    names = Enum.map(tools, & &1["name"])

    assert "agent_ask" in names
    assert "agent_approve" in names
    refute "hook_deliver" in names
    refute "channel_deliver" in names

    expected =
      for %{subject: subject} <- WardrikProtocol.operations(),
          subject not in ~w(hook channel),
          do: subject

    assert length(tools) == length(expected)

    define = Enum.find(tools, &(&1["name"] == "agent_define"))
    assert define["inputSchema"] == WardrikProtocol.operation("agent.define").input
    assert define["annotations"]["destructiveHint"] == false

    assert %{"readOnlyHint" => true} =
             Enum.find(tools, &(&1["name"] == "agent_read"))["annotations"]

    assert %{"destructiveHint" => true} =
             Enum.find(tools, &(&1["name"] == "agent_forget"))["annotations"]
  end

  test "runs a tool's operation as the caller, and answers its output", context do
    conn =
      call(context, "agent_define", %{
        "agent" => "acme/@maria/notes",
        "model" => "anthropic:claude-haiku-4-5"
      })

    assert %{
             "result" => %{"isError" => false, "structuredContent" => output, "content" => [text]}
           } =
             body(conn)

    assert %{"agent" => %{"id" => "acme/@maria/notes"}} = output
    assert JSON.decode!(text["text"]) == output

    conn = call(context, "agent_definition", %{"agent" => "acme/@maria/notes"})

    assert %{"definition" => %{"model" => "anthropic:claude-haiku-4-5"}} =
             body(conn)["result"]["structuredContent"]

    conn = call(context, "agent_forget", %{"agent" => "acme/@maria/notes"})
    assert %{"isError" => false, "content" => [%{"text" => "Done."}]} = body(conn)["result"]
  end

  test "answers an operation's error as the tool's", context do
    conn = call(context, "agent_definition", %{"agent" => "acme/@maria/nobody"})
    assert %{"isError" => true, "content" => [%{"text" => text}]} = body(conn)["result"]
    assert %{"error" => %{"type" => "not_found"}} = JSON.decode!(text)

    conn = call(context, "agent_define", %{"agent" => "acme/@maria/notes", "colour" => "red"})
    assert %{"isError" => true} = body(conn)["result"]
  end

  test "answers JSON-RPC errors for unknown tools and methods", context do
    assert %{"error" => %{"code" => -32_602}} = body(call(context, "nothing", %{}))
    assert %{"error" => %{"code" => -32_601}} = body(rpc(context, "resources/list"))

    conn = request(context, "POST", "/mcp", "{not json")
    assert {conn.status, body(conn)["error"]["code"]} == {400, -32_700}
  end

  test "serves the stateless version from each request's metadata", context do
    meta = %{"_meta" => %{@version_key => "2026-07-28"}}

    conn = rpc(context, "server/discover", meta)

    assert %{
             "supportedVersions" => ["2026-07-28"],
             "resultType" => "complete",
             "ttlMs" => 0,
             "_meta" => %{"io.modelcontextprotocol/serverInfo" => %{"name" => "wardrik"}}
           } = body(conn)["result"]

    assert %{"resultType" => "complete", "tools" => [_tool | _tools]} =
             body(rpc(context, "tools/list", meta))["result"]

    conn = rpc(context, "tools/list", %{"_meta" => %{@version_key => "2099-01-01"}})
    assert {conn.status, body(conn)["error"]["code"]} == {400, -32_022}
  end

  test "needs the caller's token", context do
    conn =
      request(%{context | secret: "wrong"}, "POST", "/mcp", %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tools/list"
      })

    assert conn.status == 401
    assert get_resp_header(conn, "www-authenticate") == ["Bearer"]
  end

  test "isn't served unless asked for", context do
    conn =
      request(%{context | http: []}, "POST", "/mcp", %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tools/list"
      })

    assert {conn.status, body(conn)["error"]["message"]} == {404, "There's no route here."}
  end

  test "answers only POST", context do
    conn = request(context, "GET", "/mcp")
    assert {conn.status, get_resp_header(conn, "allow")} == {405, ["POST"]}
  end
end
