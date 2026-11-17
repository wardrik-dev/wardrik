defmodule Wardrik.HTTP.MCP do
  @moduledoc """
  Serves Wardrik's operations as tools to MCP clients, such as Claude Code, at `/mcp`.
  `Wardrik.HTTP.Endpoint` serves it when started with `mcp: true`:

      {Wardrik.HTTP,
       wardrik: MyApp.AgentRuntime, authenticator: {MyAppWeb.WardrikSession, []}, mcp: true, port: 4000}

  Connect with a token your authenticator takes:

      claude mcp add --transport http wardrik https://agents.example.com/mcp \\
        --header "Authorization: Bearer $TOKEN"

    * Each operation is a tool, named with `_` for `.`, as `agent_ask`. Its arguments are the
      operation's input. It answers the operation's output, as JSON.
    * A call runs in the request's scope, as the operation's HTTP route does. Your authorizer
      decides it. A refused or failed call answers the error, with `isError`.
    * Deliveries from webhooks and chat apps aren't tools.
    * It's Streamable HTTP without sessions: each `POST` gets one JSON answer. `GET` and `DELETE`
      answer `405`.
    * It speaks MCP 2025-03-26, 2025-06-18, 2025-11-25 and 2026-07-28.

  To serve more tools, call `serve/2` from your own router with `build_tools/1` and your own
  `Wardrik.HTTP.MCP.Tool`s.
  """

  import Plug.Conn

  alias Wardrik.Error
  alias Wardrik.HTTP.Input
  alias Wardrik.HTTP.MCP.Tool
  alias Wardrik.HTTP.Response

  # Webhooks and chat apps call these, with the request as it came.
  @inbound ~w(hook channel)

  @versions ~w(2025-11-25 2025-06-18 2025-03-26)
  @stateless ~w(2026-07-28)
  @version_key "io.modelcontextprotocol/protocolVersion"
  @info_key "io.modelcontextprotocol/serverInfo"
  @cached ~w(server/discover tools/list)
  @capabilities %{"tools" => %{"listChanged" => false}}
  @instructions "Each tool runs one Wardrik operation as the caller, authorized as its HTTP " <>
                  "route is."

  @parse_error -32_700
  @invalid_request -32_600
  @no_method -32_601
  @invalid_params -32_602
  @unsupported_version -32_022

  @doc "Returns a tool for each operation in `WardrikProtocol` people call, run in `scope`."
  @spec build_tools(Wardrik.Scope.t()) :: [Tool.t()]
  def build_tools(scope) do
    for %{subject: subject, id: id} = operation <- WardrikProtocol.operations(),
        subject not in @inbound,
        do: Tool.new(operation, &Wardrik.Scope.run(scope, id, &1))
  end

  @doc "Answers the MCP request in `conn` with `tools`. Authenticate the request first."
  @spec serve(Plug.Conn.t(), [Tool.t()]) :: Plug.Conn.t()
  def serve(%Plug.Conn{method: "POST"} = conn, tools) do
    case Input.read_json(conn) do
      {:ok, message, conn} -> respond_to_message(conn, message, tools)
      {:error, %Error{message: message}} -> respond_with_error(conn, nil, {@parse_error, message})
    end
  end

  def serve(conn, _tools) do
    conn
    |> put_resp_header("allow", "POST")
    |> Response.json(405, %{"error" => "Send MCP requests as POST."})
  end

  defp respond_to_message(
         conn,
         %{"jsonrpc" => "2.0", "method" => method, "id" => id} = request,
         tools
       ) do
    params = Map.get(request, "params", %{})

    with {:ok, era} <- detect_era(params),
         {:ok, result} <- handle_request(method, params, era, tools) do
      Response.json(conn, 200, %{
        "jsonrpc" => "2.0",
        "id" => id,
        "result" => shape_result(result, method, era)
      })
    else
      {:error, {code, _message, _data} = error} when code == @unsupported_version ->
        respond_with_error(conn, id, error)

      {:error, error} ->
        Response.json(conn, 200, %{"jsonrpc" => "2.0", "id" => id, "error" => encode_error(error)})
    end
  end

  # Notifications, and answers to requests this server never sends.
  defp respond_to_message(conn, %{"jsonrpc" => "2.0"} = message, _tools)
       when is_map_key(message, "method") or is_map_key(message, "result") or
              is_map_key(message, "error"),
       do: send_resp(conn, 202, "")

  defp respond_to_message(conn, _message, _tools),
    do: respond_with_error(conn, nil, {@invalid_request, "Send one JSON-RPC 2.0 message.", nil})

  defp respond_with_error(conn, id, {code, message}),
    do: respond_with_error(conn, id, {code, message, nil})

  defp respond_with_error(conn, id, error),
    do:
      Response.json(conn, 400, %{"jsonrpc" => "2.0", "id" => id, "error" => encode_error(error)})

  defp encode_error({code, message, nil}), do: %{"code" => code, "message" => message}

  defp encode_error({code, message, data}),
    do: %{"code" => code, "message" => message, "data" => data}

  # A request of the stateless versions names its version in its metadata. Others agreed on one
  # in `initialize`.
  defp detect_era(%{"_meta" => %{@version_key => version}}) when version in @stateless,
    do: {:ok, :stateless}

  defp detect_era(%{"_meta" => %{@version_key => version}}),
    do:
      {:error,
       {@unsupported_version, "Unsupported protocol version",
        %{"supported" => @stateless, "requested" => version}}}

  defp detect_era(_params), do: {:ok, :legacy}

  defp handle_request("initialize", params, :legacy, _tools) do
    {:ok,
     %{
       "protocolVersion" => negotiate_version(params["protocolVersion"]),
       "capabilities" => @capabilities,
       "serverInfo" => build_server_info(),
       "instructions" => @instructions
     }}
  end

  defp handle_request("server/discover", _params, _era, _tools) do
    {:ok,
     %{
       "supportedVersions" => @stateless,
       "capabilities" => @capabilities,
       "instructions" => @instructions
     }}
  end

  defp handle_request("ping", _params, _era, _tools), do: {:ok, %{}}

  defp handle_request("tools/list", _params, _era, tools),
    do: {:ok, %{"tools" => Enum.map(tools, &Tool.encode/1)}}

  defp handle_request("tools/call", %{"name" => name} = params, _era, tools) do
    case {Enum.find(tools, &(&1.name == name)), Map.get(params, "arguments", %{})} do
      {nil, _arguments} -> {:error, {@invalid_params, "There's no tool #{name}.", nil}}
      {tool, %{} = arguments} -> {:ok, encode_tool_result(tool.run.(arguments))}
      {_tool, _arguments} -> {:error, {@invalid_params, "Send arguments as an object.", nil}}
    end
  end

  defp handle_request("tools/call", _params, _era, _tools),
    do: {:error, {@invalid_params, "Name the tool to call.", nil}}

  defp handle_request(method, _params, _era, _tools),
    do: {:error, {@no_method, "There's no method #{method}.", nil}}

  defp negotiate_version(version) when version in @versions, do: version
  defp negotiate_version(_version), do: hd(@versions)

  defp build_server_info,
    do: %{
      "name" => "wardrik",
      "title" => "Wardrik",
      "version" => to_string(Application.spec(:wardrik, :vsn))
    }

  defp encode_tool_result({:ok, nil}),
    do: %{"content" => [build_text_content("Done.")], "isError" => false}

  defp encode_tool_result({:ok, %{} = output}),
    do: %{
      "content" => [build_text_content(JSON.encode!(output))],
      "structuredContent" => output,
      "isError" => false
    }

  defp encode_tool_result({:ok, output}),
    do: %{"content" => [build_text_content(JSON.encode!(output))], "isError" => false}

  defp encode_tool_result({:error, %Error{} = error}) do
    json =
      error
      |> Error.json()
      |> JSON.encode!()

    %{"content" => [build_text_content(json)], "isError" => true}
  end

  defp build_text_content(text), do: %{"type" => "text", "text" => text}

  # The stateless versions give every result its type and the server's name, and say how long a
  # list may be kept: not at all, since what a caller may do can change.
  defp shape_result(result, method, :stateless) do
    result
    |> Map.put("resultType", "complete")
    |> Map.put("_meta", %{@info_key => build_server_info()})
    |> put_cache_hints(method)
  end

  defp shape_result(result, _method, :legacy), do: result

  defp put_cache_hints(result, method) when method in @cached,
    do: Map.merge(result, %{"ttlMs" => 0, "cacheScope" => "private"})

  defp put_cache_hints(result, _method), do: result
end
