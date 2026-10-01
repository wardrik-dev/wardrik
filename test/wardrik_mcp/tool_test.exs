defmodule WardrikMCP.ToolTest do
  use ExUnit.Case, async: true

  alias Anubis.MCP.Error
  alias Anubis.MCP.Response
  alias WardrikMCP.Server
  alias WardrikMCP.Tool

  defp server(opts \\ []) do
    Server.new(:stub, Keyword.put_new(opts, :transport, {:stdio, command: "true"}))
  end

  defp answered(result, opts \\ []) do
    Tool.answer(
      {:ok, %Response{result: result, id: "1", is_error: result["isError"] == true}},
      server(opts)
    )
  end

  describe "build/2" do
    test "takes the server's schema as the tool's own" do
      schema = %{"type" => "object", "properties" => %{"q" => %{"type" => "string"}}}

      tool =
        Tool.build(server(), %{
          "name" => "search",
          "description" => "Find",
          "inputSchema" => schema
        })

      assert tool.name == "stub__search"
      assert tool.parameter_schema == schema
      assert tool.description =~ "Find"
    end

    test "a tool describing nothing still has a description and a schema" do
      tool = Tool.build(server(), %{"name" => "bare"})

      assert tool.description =~ "bare"
      assert tool.parameter_schema == %{"type" => "object", "properties" => %{}}
    end

    test "falls back to a title where there is no description" do
      tool = Tool.build(server(), %{"name" => "t", "title" => "The Title"})

      assert tool.description =~ "The Title"
    end
  end

  describe "answer/2" do
    test "joins text content" do
      result = %{
        "content" => [%{"type" => "text", "text" => "one"}, %{"type" => "text", "text" => "two"}]
      }

      assert {:ok, %{"result" => %{"content" => "one\ntwo"}}} = answered(result)
    end

    test "reads an embedded resource's text" do
      result = %{"content" => [%{"type" => "resource", "resource" => %{"text" => "inside"}}]}

      assert {:ok, %{"result" => %{"content" => "inside"}}} = answered(result)
    end

    test "says so where content cannot be read as text" do
      result = %{"content" => [%{"type" => "image", "data" => "..."}]}

      assert {:ok, %{"result" => %{"content" => content}}} = answered(result)
      assert content =~ "image content"
    end

    test "prefers structured content where a server sends it" do
      result = %{
        "content" => [%{"type" => "text", "text" => "ignored"}],
        "structuredContent" => %{"n" => 1}
      }

      assert {:ok, %{"result" => %{"n" => 1}}} = answered(result)
    end

    test "a result with no content at all is still an answer" do
      assert {:ok, %{"result" => %{"content" => content}}} = answered(%{"other" => true})
      assert content =~ "other"
    end

    test "a tool error keeps the server's words" do
      result = %{"content" => [%{"type" => "text", "text" => "refused"}], "isError" => true}

      assert {:ok, %{"ok" => false, "error" => error}} = answered(result)
      assert error["message"] =~ "refused"
    end

    test "a protocol error is an error result, not a raise" do
      error = Error.transport(:timeout, %{})

      assert {:ok, %{"ok" => false, "error" => reported}} = Tool.answer({:error, error}, server())
      assert reported["code"] == "timeout"
    end

    test "cuts a long result on a character boundary" do
      long = String.duplicate("é", 100)
      result = %{"content" => [%{"type" => "text", "text" => long}]}

      assert {:ok, %{"result" => %{"content" => content}}} =
               answered(result, max_result_bytes: 15)

      assert String.valid?(content)
      assert content =~ "[cut:"
    end

    test "leaves a result whole where the cap is lifted" do
      result = %{"content" => [%{"type" => "text", "text" => String.duplicate("a", 500)}]}

      assert {:ok, %{"result" => %{"content" => content}}} =
               answered(result, max_result_bytes: :infinity)

      refute content =~ "[cut:"
    end
  end

  describe "with_credential/2" do
    test "puts a bearer header on an HTTP transport" do
      server = server(transport: {:streamable_http, base_url: "https://example.com"})

      assert {:ok, {:streamable_http, opts}} =
               Server.with_credential(server, Wardrik.Credential.secret("tok"))

      assert opts[:headers] == %{"authorization" => "Bearer tok"}
    end

    test "keeps the headers the transport already had" do
      server =
        server(transport: {:streamable_http, base_url: "https://x", headers: %{"x-trace" => "1"}})

      {:ok, {_layer, opts}} = Server.with_credential(server, Wardrik.Credential.secret("tok"))

      assert opts[:headers] == %{"x-trace" => "1", "authorization" => "Bearer tok"}
    end

    test "takes a scheme and a header of the deployment's choosing" do
      server =
        server(
          transport: {:streamable_http, base_url: "https://x"},
          credential_header: "x-api-key",
          credential_scheme: ""
        )

      {:ok, {_layer, opts}} = Server.with_credential(server, Wardrik.Credential.secret("tok"))

      assert opts[:headers] == %{"x-api-key" => "tok"}
    end

    test "gives a command its token through the environment" do
      server = server(transport: {:stdio, command: "x"}, credential_env: "TOKEN")

      assert {:ok, {:stdio, opts}} =
               Server.with_credential(server, Wardrik.Credential.secret("tok"))

      assert opts[:env]["TOKEN"] == "tok"
    end

    test "a command with nowhere to put a token says so" do
      assert {:error, message} =
               Server.with_credential(server(), Wardrik.Credential.secret("tok"))

      assert message =~ ":credential_env"
    end
  end

  describe "per_user?/1" do
    test "is what naming a credential means" do
      refute Server.per_user?(server())
      assert Server.per_user?(server(credential: "github"))
    end
  end
end
