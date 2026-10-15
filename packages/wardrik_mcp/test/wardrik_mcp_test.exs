defmodule WardrikMCPTest do
  use WardrikMCP.Test.Case, async: false

  alias Wardrik.LLM.Config
  alias Wardrik.Servers.Key
  alias Wardrik.Test.Calls
  alias Wardrik.Tool

  defp offered(key),
    do:
      Enum.map(
        ~w(echo boom secret slow noisy refuses_once noise cancellations grow),
        &"#{key}__#{&1}"
      )

  describe "tools/1" do
    test "offers every tool the server listed, under the server's name", %{key: key} do
      assert Enum.map(WardrikMCP.tools(key), & &1.name) == offered(key)
    end

    test "carries the server's own schema and description", %{key: key} do
      [echo | _rest] = WardrikMCP.tools(key)

      assert echo.description =~ "Hands the value back."
      assert echo.description =~ "MCP server"
      assert echo.parameter_schema["required"] == ["value"]
    end

    test "a key nothing is connected under offers nothing" do
      assert WardrikMCP.tools(Key.deployment("never_connected")) == []
    end
  end

  describe "as a tool source" do
    test "a config names the server and builds its tools", %{key: key} do
      config = Config.new(tools: [{WardrikMCP, key}])

      assert Enum.map(Config.tools(config), & &1.name) == offered(key)
    end

    test "the spec travels, and builds the same tools again", %{key: key} do
      config = Config.new(tools: [{WardrikMCP, key}])

      loaded = config |> Config.dump() |> Config.load()

      assert loaded.tools == [{WardrikMCP, key}]

      assert Enum.map(Config.tools(loaded), & &1.name) ==
               Enum.map(Config.tools(config), & &1.name)
    end

    test "a tool from a server reads the timeout the source declares", %{key: key} do
      config = Config.new(tools: [{WardrikMCP, key}])

      assert Config.tool_timeout(config, "#{key}__echo") == :timer.seconds(60)
    end

    test "a config holding a server that never answers is still valid" do
      config = Config.new(tools: [{WardrikMCP, Key.deployment("never_connected")}])

      assert Config.tools(config) == []
      assert Tool.available?({WardrikMCP, Key.deployment("never_connected")})
    end
  end

  describe "call/3" do
    test "calls the tool and hands back what the server answered", %{key: key} do
      assert {:ok, %{"ok" => true, "result" => %{"content" => "hello"}}} =
               WardrikMCP.call(key, "echo", %{"value" => "hello"}, context())
    end

    test "takes arguments with atom keys", %{key: key} do
      assert {:ok, %{"result" => %{"content" => "hello"}}} =
               WardrikMCP.call(key, "echo", %{value: "hello"}, context())
    end

    test "a tool error from the server is an error result, not a crash", %{key: key} do
      assert {:ok, %{"ok" => false, "error" => error}} =
               WardrikMCP.call(key, "boom", %{}, context())

      assert error["code"] == "mcp_tool_error"
      assert error["message"] =~ "the tool refused"
    end

    @tag server_opts: [serves: [Wardrik.AgentID.Prefix.tenant!("acme")]]
    test "a server serves the agents under the prefixes it names, and refuses another's", %{
      key: key
    } do
      scope = fn org -> Wardrik.Test.scope(id: Wardrik.AgentID.new!("x", org: org)) end

      assert {:ok, %{"ok" => true}} =
               WardrikMCP.call(key, "echo", %{value: "hi"}, context(scope.("acme")))

      assert {:ok, %{"ok" => false, "error" => error}} =
               WardrikMCP.call(key, "echo", %{value: "hi"}, context(scope.("globex")))

      assert error["message"] =~ "#{key} does not serve globex/x"
    end

    test "a server that is not connected answers as an error" do
      assert {:ok, %{"ok" => false, "error" => error}} =
               WardrikMCP.call(Key.deployment("never_connected"), "echo", %{}, context())

      assert error["message"] =~ "no MCP server is connected"
    end

    test "a call to the server's tool runs through to it", %{key: key} do
      [echo | _rest] = WardrikMCP.tools(key)
      scope = Wardrik.Test.scope(tools: [{WardrikMCP, key}])

      assert {:ok, %{"result" => %{"content" => "through"}}} =
               scope |> Wardrik.Test.call(echo.name, %{"value" => "through"}) |> Calls.result()
    end
  end

  describe "servers/0 and disconnect/1" do
    test "lists what is connected, and forgets what is stopped", %{key: key} do
      assert key in WardrikMCP.servers()

      assert :ok = WardrikMCP.disconnect(key)

      refute key in WardrikMCP.servers()
      assert WardrikMCP.tools(key) == []
    end
  end
end
