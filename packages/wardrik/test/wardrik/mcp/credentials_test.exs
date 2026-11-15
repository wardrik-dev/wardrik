defmodule Wardrik.MCP.CredentialsTest do
  use Wardrik.MCPCase, async: true

  describe "a server each principal reaches with their own credential" do
    setup do
      server = [
        transport: @stub,
        credential_name: "stub",
        credential_env: "STUB_TOKEN",
        only: ["whoami"]
      ]

      :ok = Wardrik.MCP.add(@mcp, "own", server)
      on_exit(fn -> Wardrik.MCP.remove(@mcp, "own") end)
    end

    defp own(context), do: Wardrik.MCP.tools(context, name: @mcp, servers: "own")

    defp ask(context, name) do
      call = %ToolCall{id: "1", name: "own__" <> name, arguments: %{}}

      context
      |> own()
      |> Tool.call(call, context)
    end

    test "offers connecting until someone has, then each calls it as themselves" do
      ada = context("ada", %{"ada" => "ada-token"})
      grace = context("grace", %{})

      offered = own(ada)
      assert ["own__connect"] = Enum.map(offered, & &1.name)

      assert {:park,
              %Wardrik.Credentials.Authorization{url: "https://sign.in/grace", credential: "stub"}} =
               ask(grace, "connect")

      assert {:ok, "Connected to own." <> _} = ask(ada, "connect")

      offered = own(ada)
      assert ["own__whoami"] = Enum.map(offered, & &1.name)
      assert {:ok, "ada-token", _context} = ask(ada, "whoami")

      linus = context("linus", %{"linus" => "linus-token"})
      assert {:ok, "linus-token", _context} = ask(linus, "whoami")

      renewed = context("ada", %{"ada" => "ada-renewed"})
      assert {:ok, "ada-renewed", _context} = ask(renewed, "whoami")

      assert {:park, %Wardrik.Credentials.Authorization{}} = ask(grace, "whoami")
    end

    test "says when it can't be reached, or there's nothing to reach it with" do
      :ok =
        Wardrik.MCP.add(@mcp, "broken",
          transport: {:stdio, command: "no-such-mcp-server"},
          credential_name: "stub"
        )

      ada = context("ada", %{"ada" => "ada-token"})
      call = %ToolCall{id: "1", name: "broken__connect", arguments: %{}}

      broken = Wardrik.MCP.tools(ada, name: @mcp, servers: "broken")
      assert {:error, "broken didn't connect" <> _} = Tool.call(broken, call, ada)

      bare = Context.new(agent_id: "mcp-test", principal: %Wardrik.Principal{id: "ada"})
      assert {:error, "own didn't connect" <> _} = ask(bare, "connect")

      :ok = Wardrik.MCP.remove(@mcp, "broken")
    end

    test "reports a credential the server refuses, and calls again with it renewed" do
      test = self()
      {:ok, tokens} = Agent.start_link(fn -> %{token: "ada-token", test: test} end)

      ada =
        Context.new(
          agent_id: "mcp-test",
          principal: %Wardrik.Principal{id: "ada"},
          credentials: {Wardrik.MCPCase.Rotating, tokens}
        )

      assert {:ok, "Connected to own." <> _} = ask(ada, "connect")

      refusal = %Anubis.MCP.Error{data: %{original_reason: {:authorization_required, %{}}}}
      stub(Anubis.Client, :call_tool, &call_original(Anubis.Client, :call_tool, [&1, &2, &3, &4]))

      expect(Anubis.Client, :call_tool, fn _client, _name, _arguments, _opts ->
        {:error, refusal}
      end)

      assert {:ok, "ada-token-renewed", _context} = ask(ada, "whoami")
      assert_received {:refused, "ada-token"}

      expect(Anubis.Client, :call_tool, 2, fn _client, _name, _arguments, _opts ->
        {:error, refusal}
      end)

      assert {:error, _refused, _context} = ask(ada, "whoami")
    end

    test "closes every connection to it when it's removed" do
      ada = context("ada", %{"ada" => "ada-token"})
      assert {:ok, "Connected to own." <> _} = ask(ada, "connect")

      assert :ok = Wardrik.MCP.remove(@mcp, "own")
      assert own(ada) == []
    end
  end
end
