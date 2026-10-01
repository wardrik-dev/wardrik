defmodule WardrikMCPTest do
  use WardrikMCP.Case, async: false

  alias Wardrik.LLM.Config
  alias Wardrik.Test.Calls
  alias Wardrik.Tool

  defp offered(ref),
    do:
      Enum.map(
        ~w(echo boom secret slow noisy refuses_once noise cancellations grow),
        &"#{ref}__#{&1}"
      )

  describe "tools/1" do
    test "offers every tool the server listed, under the server's name", %{ref: ref} do
      assert Enum.map(WardrikMCP.tools(ref), & &1.name) == offered(ref)
    end

    test "carries the server's own schema and description", %{ref: ref} do
      [echo | _rest] = WardrikMCP.tools(ref)

      assert echo.description =~ "Hands the value back."
      assert echo.description =~ "MCP server"
      assert echo.parameter_schema["required"] == ["value"]
    end

    test "a ref nothing is connected under offers nothing" do
      assert WardrikMCP.tools(:never_connected) == []
    end
  end

  describe "as a tool source" do
    test "a config names the server and builds its tools", %{ref: ref} do
      config = Config.new(tools: [{WardrikMCP, ref}])

      assert Enum.map(Config.tools(config), & &1.name) == offered(ref)
    end

    test "the spec travels, and builds the same tools again", %{ref: ref} do
      config = Config.new(tools: [{WardrikMCP, ref}])

      loaded = config |> Config.dump() |> Config.load()

      assert loaded.tools == [{WardrikMCP, ref}]

      assert Enum.map(Config.tools(loaded), & &1.name) ==
               Enum.map(Config.tools(config), & &1.name)
    end

    test "a tool from a server reads the timeout the source declares", %{ref: ref} do
      config = Config.new(tools: [{WardrikMCP, ref}])

      assert Config.tool_timeout(config, "#{ref}__echo") == :timer.seconds(60)
    end

    test "a config holding a server that never answers is still valid" do
      config = Config.new(tools: [{WardrikMCP, :never_connected}])

      assert Config.tools(config) == []
      assert Tool.available?({WardrikMCP, :never_connected})
    end
  end

  describe "call/3" do
    test "calls the tool and hands back what the server answered", %{ref: ref} do
      assert {:ok, %{"ok" => true, "result" => %{"content" => "hello"}}} =
               WardrikMCP.call(ref, "echo", Calls.tool("echo", %{"value" => "hello"}))
               |> Calls.result()
    end

    test "takes arguments with atom keys", %{ref: ref} do
      assert {:ok, %{"result" => %{"content" => "hello"}}} =
               WardrikMCP.call(ref, "echo", Calls.tool("echo", %{value: "hello"}))
               |> Calls.result()
    end

    test "a tool error from the server is an error result, not a crash", %{ref: ref} do
      assert {:ok, %{"ok" => false, "error" => error}} =
               WardrikMCP.call(ref, "boom", Calls.tool("boom", %{}))
               |> Calls.result()

      assert error["code"] == "mcp_tool_error"
      assert error["message"] =~ "the tool refused"
    end

    @tag server_opts: [orgs: ["acme"]]
    test "a server serves the agents of the orgs it names, and refuses another org's", %{
      ref: ref
    } do
      scope = fn org -> Wardrik.Scope.root(Config.new(), org <> "/x", org: org) end

      assert {:ok, %{"ok" => true}} =
               WardrikMCP.call(ref, "echo", Calls.tool("echo", %{value: "hi"}, scope.("acme")))
               |> Calls.result()

      for scope <- [scope.("globex"), nil] do
        assert {:ok, %{"ok" => false, "error" => error}} =
                 WardrikMCP.call(ref, "echo", Calls.tool("echo", %{value: "hi"}, scope))
                 |> Calls.result()

        assert error["message"] =~ "#{ref} "
        assert error["message"] =~ ~r/does not serve globex's agents|this call is from none/
      end
    end

    test "a server that is not connected answers as an error" do
      assert {:ok, %{"ok" => false, "error" => error}} =
               WardrikMCP.call(:never_connected, "echo", Calls.tool("echo", %{}))
               |> Calls.result()

      assert error["message"] =~ "no MCP server is connected"
    end

    test "the built tool calls through to the server", %{ref: ref} do
      [echo | _rest] = WardrikMCP.tools(ref)

      assert {:ok, %{"result" => %{"content" => "through"}}} =
               Calls.run(echo, %{"value" => "through"})
    end
  end

  describe "servers/0 and disconnect/1" do
    test "lists what is connected, and forgets what is stopped", %{ref: ref} do
      assert ref in WardrikMCP.servers()

      assert :ok = WardrikMCP.disconnect(ref)

      refute ref in WardrikMCP.servers()
      assert WardrikMCP.tools(ref) == []
    end
  end
end
