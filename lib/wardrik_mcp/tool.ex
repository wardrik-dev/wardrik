defmodule WardrikMCP.Tool do
  @moduledoc """
  One tool on an MCP server, as an agent sees it.

  `build/2` turns a `tools/list` entry into a `ReqLLM.Tool`, named for the
  server it came from and carrying the server's own JSON Schema. Calling it
  sends `tools/call` and hands back the content the server answered with.

  A result reaches the model as text, or as the server's structured content
  where it sends any, cut to the server's `:max_result_bytes`.
  """

  alias Wardrik.Tool.Result
  alias WardrikMCP.Server

  @truncated "\n\n[cut: the rest of this result was longer than the server's limit]"

  @doc """
  The one tool a server offers before anyone has authorized it.

  A server reached as a user will not list its tools to a connection with no
  credential, so there is nothing to offer until somebody connects and nothing
  to call to make them. This is what breaks that: the agent calls it, the call
  parks on the authorization link, and the user's own connection lists the real
  tools in its place.
  """
  @spec connect(Server.t()) :: ReqLLM.Tool.t()
  def connect(%Server{} = server) do
    {:module, WardrikMCP} = Code.ensure_loaded(WardrikMCP)

    Wardrik.Tool.new!(
      name: Server.local_name(server, "connect"),
      description: """
      Authorize this agent to use #{server.ref}. Call it when you need #{server.ref}       and no #{server.ref} tool is available yet: the user is asked to connect, and       #{server.ref}'s own tools appear once they have.
      """,
      parameter_schema: %{"type" => "object", "properties" => %{}},
      call: {WardrikMCP, :authorize, [server.ref]}
    )
  end

  @doc "Builds the tool a `tools/list` entry describes."
  @spec build(Server.t(), map()) :: ReqLLM.Tool.t()
  def build(%Server{} = server, %{"name" => name} = listed) do
    # ReqLLM checks an MFA callback with function_exported?/3, which is false
    # for a module nothing has loaded yet.
    {:module, WardrikMCP} = Code.ensure_loaded(WardrikMCP)

    Wardrik.Tool.new!(
      name: Server.local_name(server, name),
      description: description(listed, server),
      parameter_schema: listed["inputSchema"] || %{"type" => "object", "properties" => %{}},
      call: {WardrikMCP, :call, [server.ref, name]}
    )
  end

  @doc "Reads a `tools/call` answer as a tool result."
  @spec answer({:ok, Anubis.MCP.Response.t()} | {:error, Anubis.MCP.Error.t()}, Server.t()) ::
          Result.t()
  def answer({:ok, %Anubis.MCP.Response{is_error: true} = response}, %Server{} = server) do
    Result.error(:mcp_tool_error, text(response.result, server))
  end

  def answer({:ok, %Anubis.MCP.Response{result: result}}, %Server{} = server) do
    case result["structuredContent"] do
      nil -> Result.ok(%{"content" => text(result, server)})
      structured -> Result.ok(structured)
    end
  end

  def answer({:error, %Anubis.MCP.Error{} = error}, %Server{}) do
    Result.error(error.reason, describe(error))
  end

  defp describe(%Anubis.MCP.Error{} = error), do: "#{error.message} (#{error.reason})"

  defp description(listed, server) do
    (listed["description"] || listed["title"] || listed["name"]) <>
      "\n\nFrom the #{server.ref} MCP server."
  end

  defp text(%{"content" => content}, server) when is_list(content) do
    content
    |> Enum.map_join("\n", &content_text/1)
    |> cut(server.max_result_bytes)
  end

  defp text(result, server), do: result |> inspect() |> cut(server.max_result_bytes)

  defp content_text(%{"type" => "text", "text" => text}), do: text
  defp content_text(%{"type" => "resource", "resource" => %{"text" => text}}), do: text
  defp content_text(%{"type" => type}), do: "[#{type} content, which cannot be read as text]"
  defp content_text(other), do: inspect(other)

  defp cut(text, :infinity), do: text

  defp cut(text, max_bytes) when byte_size(text) > max_bytes do
    text |> binary_part(0, max_bytes) |> whole_characters() |> Kernel.<>(@truncated)
  end

  defp cut(text, _max_bytes), do: text

  # A cut lands mid-character often enough, and a tool result must be valid
  # UTF-8 to be encoded for the model.
  defp whole_characters(""), do: ""

  defp whole_characters(text) do
    if String.valid?(text),
      do: text,
      else: text |> binary_part(0, byte_size(text) - 1) |> whole_characters()
  end
end
