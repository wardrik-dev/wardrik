defmodule Wardrik.MCP.ServersTest do
  use Wardrik.MCPCase, async: true

  describe "servers added as the app runs" do
    test "reaches a server once it's added, and nothing of it once it's removed" do
      listen()

      assert :ok =
               Wardrik.MCP.add(@mcp, "added", transport: @stub, only: ["echo"], prefix: "extra")

      assert_receive {:tools, @mcp, "added", %{count: 1}}, 10_000

      assert "added" in Wardrik.MCP.servers(@mcp)
      added = tools("added")
      assert ["extra__echo"] = Enum.map(added, & &1.name)

      assert :ok = Wardrik.MCP.remove(@mcp, "added")
      refute "added" in Wardrik.MCP.servers(@mcp)
      assert tools("added") == []
      assert {:error, :not_found} = Wardrik.MCP.remove(@mcp, "added")
    end

    test "says why it can't add or remove a server" do
      assert {:error, "stub is a server already"} =
               Wardrik.MCP.add(@mcp, "stub", transport: @stub)

      assert {:error, "stub is a server the app starts with"} = Wardrik.MCP.remove(@mcp, "stub")

      assert {:error, "unknown options [:colour]" <> _} =
               Wardrik.MCP.add(@mcp, "odd", transport: @stub, colour: "blue")

      assert {:error, "a server added as the app runs takes its options as data"} =
               Wardrik.MCP.add(@mcp, "priced", transport: @stub, cost: &Map.new/1)
    end

    test "reaches what another node added, through the store they share" do
      listen()
      store = Wardrik.Store.ETS.new(name: Wardrik.MCPCase.Store)
      start_supervised!({Wardrik.Store, store}, id: :store)

      for {name, id} <- [{Wardrik.MCPCase.One, :one}, {Wardrik.MCPCase.Two, :two}] do
        start_supervised!({Wardrik.MCP, name: name, store: store, reconcile: :infinity}, id: id)
      end

      assert :ok =
               Wardrik.MCP.add(Wardrik.MCPCase.One, "shared", transport: @stub, only: ["echo"])

      assert :ok = Wardrik.MCP.reconcile(Wardrik.MCPCase.Two)

      assert_receive {:tools, Wardrik.MCPCase.Two, "shared", %{count: 1}}, 10_000
      assert "shared" in Wardrik.MCP.servers(Wardrik.MCPCase.Two)

      assert :ok = Wardrik.MCP.remove(Wardrik.MCPCase.One, "shared")
      assert :ok = Wardrik.MCP.reconcile(Wardrik.MCPCase.Two)
      refute "shared" in Wardrik.MCP.servers(Wardrik.MCPCase.Two)
    end
  end

  test "reaches a server over HTTP at exactly the URL it's given" do
    listen()

    for {name, path} <- [{"ending", "/mcp"}, {"nested", "/v1/tools/"}, {"root", "/"}] do
      port = Wardrik.MCP.HTTPStub.start(self(), path)
      url = "http://127.0.0.1:#{port}" <> if(path == "/", do: "", else: path)

      :ok = Wardrik.MCP.add(@mcp, name, transport: {:streamable_http, url: url})
      on_exit(fn -> Wardrik.MCP.remove(@mcp, name) end)
      connected(name)

      offered = tools(name)
      assert ["#{name}__ping"] == Enum.map(offered, & &1.name)
      assert [^path | _rest] = paths = requested()
      assert Enum.uniq(paths) == [path]
    end
  end

  test "refuses a server over HTTP without an http or https URL" do
    transport = {:streamable_http, url: "mcp.example.com/mcp"}
    assert {:error, _reason} = Wardrik.MCP.add(@mcp, "bad", transport: transport)
  end

  describe "a server whose headers name secrets" do
    setup do
      test = self()
      {:ok, secrets} = Agent.start_link(fn -> %{{"acme", "KEY"} => "one"} end)

      secret = fn owner, name ->
        send(test, {:read, owner, name})

        case Agent.get(secrets, &Map.fetch(&1, {owner, name})) do
          {:ok, value} -> {:ok, value}
          :error -> {:error, :not_found}
        end
      end

      start_supervised!({Wardrik.MCP, name: Wardrik.MCPCase.Secrets, secret: secret},
        id: :secrets
      )

      port = Wardrik.MCP.HTTPStub.start(test, "/mcp")
      %{secrets: secrets, url: "http://127.0.0.1:#{port}/mcp"}
    end

    defp secured(url, owner, value),
      do: [
        transport: {:streamable_http, url: url, headers: %{"authorization" => value}},
        owner: owner
      ]

    test "reads them for its owner as it connects, and again once reconnected", %{
      secrets: secrets,
      url: url
    } do
      server = secured(url, "acme", ["Bearer ", {:secret, "KEY"}])
      assert :ok = Wardrik.MCP.add(Wardrik.MCPCase.Secrets, "crm", server)

      assert_receive {:read, "acme", "KEY"}
      assert_receive {:authorization, "Bearer one"}, 5_000

      Agent.update(secrets, &Map.put(&1, {"acme", "KEY"}, "two"))
      assert :ok = Wardrik.MCP.reconnect(Wardrik.MCPCase.Secrets, owner: "globex", secret: "KEY")
      refute_receive {:read, _owner, _name}, 200

      assert :ok = Wardrik.MCP.reconnect(Wardrik.MCPCase.Secrets, owner: "acme", secret: "KEY")
      assert_receive {:authorization, "Bearer two"}, 5_000
    end

    test "is down while one can't be read, and says why", %{url: url} do
      theirs = secured(url, "globex", {:secret, "KEY"})
      server = Server.new!("theirs", theirs)

      assert Server.resolved(server) ==
               {:error, "the secret KEY can't be read: Wardrik.MCP was given no :secret"}

      assert Server.resolved(%{server | secret: fn _owner, _name -> {:error, :not_found} end}) ==
               {:error, "the secret KEY can't be read: :not_found"}

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          :ok = Wardrik.MCP.add(Wardrik.MCPCase.Secrets, "theirs", theirs)
          assert_receive {:read, "globex", "KEY"}
          :ok = Wardrik.MCP.remove(Wardrik.MCPCase.Secrets, "theirs")
        end)

      assert log =~
               "globex's MCP server theirs is down: \"the secret KEY can't be read: :not_found\""

      assert Wardrik.MCP.tools(context(), name: Wardrik.MCPCase.Secrets, servers: "theirs") == []
    end
  end

  describe "servers added under a check" do
    setup do
      test = self()
      {:ok, answers} = Agent.start_link(fn -> [:ok, {:error, "it's private"}] end)

      check = fn url ->
        send(test, {:checked, url})
        Agent.get_and_update(answers, &answered/1)
      end

      start_supervised!({Wardrik.MCP, name: Wardrik.MCPCase.Checked, check: check}, id: :checked)
      :ok
    end

    test "holds each URL to the check as it's added, and as each connection starts" do
      url = "https://mcp.example.com/mcp"

      assert :ok =
               Wardrik.MCP.add(Wardrik.MCPCase.Checked, "remote",
                 transport: {:streamable_http, url: url}
               )

      assert_receive {:checked, ^url}
      assert_receive {:checked, ^url}

      assert {:error, "https://mcp.example.com/mcp can't be reached: it's private"} =
               Wardrik.MCP.add(Wardrik.MCPCase.Checked, "again",
                 transport: {:streamable_http, url: url}
               )
    end

    test "reaches a server added as the app runs over HTTP alone" do
      assert {:error, "a server added as the app runs is reached over HTTP"} =
               Wardrik.MCP.add(Wardrik.MCPCase.Checked, "local", transport: @stub)
    end
  end

  test "starts a command with the variables it's given, and only a few of its own" do
    System.put_env("WARDRIK_MCP_SENTINEL", "secret")
    on_exit(fn -> System.delete_env("WARDRIK_MCP_SENTINEL") end)
    listen()

    {:stdio, opts} = @stub

    :ok =
      Wardrik.MCP.add(@mcp, "isolated",
        transport: {:stdio, [env: %{"STUB_SETTING" => "set"}] ++ opts}
      )

    on_exit(fn -> Wardrik.MCP.remove(@mcp, "isolated") end)
    connected("isolated")

    assert {:ok, env, _context} = call("isolated", "env")
    env = JSON.decode!(env)

    assert env["STUB_SETTING"] == "set"
    assert env["PATH"] == System.get_env("PATH")
    assert env["WARDRIK_MCP_SENTINEL"] == nil
  end
end
