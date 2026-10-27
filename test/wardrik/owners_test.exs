defmodule Wardrik.OwnersTest do
  use ExUnit.Case, async: false

  import Wardrik.Test.Wardrik

  alias Wardrik.MCPTools
  alias Wardrik.Statement
  alias WardrikCore.Principal

  setup {Req.Test, :set_req_test_to_shared}

  setup context do
    Req.Test.stub(__MODULE__, &authorization_server/1)

    wardrik =
      Wardrik.new(
        name: :"wardrik #{context.test}",
        keys: [WardrikVault.generate_key()],
        egress: &Wardrik.Egress.any/1,
        oauth: [
          page: "https://agents.test/oauth",
          client_name: "Acme Agents",
          req_options: [plug: {Req.Test, __MODULE__}],
          providers: [
            mail: [
              authorization_endpoint: "https://mail.test/authorize",
              token_endpoint: "https://mail.test/token",
              client_id: "wardrik"
            ]
          ]
        ]
      )

    start_supervised!({Wardrik, wardrik})
    %{wardrik: wardrik, scope: owner(wardrik)}
  end

  defp authorization_server(conn) do
    case {conn.method, conn.request_path} do
      {"GET", "/.well-known/oauth-protected-resource/mcp"} ->
        Req.Test.json(conn, %{"authorization_servers" => ["https://auth.test"]})

      {"GET", "/.well-known/oauth-authorization-server"} ->
        Req.Test.json(conn, %{
          "issuer" => "https://auth.test",
          "authorization_endpoint" => "https://auth.test/authorize",
          "token_endpoint" => "https://auth.test/token",
          "registration_endpoint" => "https://auth.test/register"
        })

      {"POST", "/register"} ->
        conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"client_id" => "registered"})
    end
  end

  defp hold(wardrik, owner, name, value),
    do: {:ok, _vsn} = WardrikVault.put(Wardrik.vault(wardrik), %Principal{id: owner}, name, value)

  defp types(scope) do
    %{"events" => changes} = run!(scope, "audit.list", %{})
    Enum.map(changes, & &1["type"])
  end

  test "names the client a service shows people signing in as the Wardrik's oauth says", %{
    wardrik: wardrik
  } do
    {WardrikOAuth.Plug, oauth} = Wardrik.sign_in_pages(wardrik)
    assert %{"client_name" => "Acme Agents"} = WardrikOAuth.client_document(oauth)
  end

  describe "connections" do
    test "lists, connects and forgets an owner's accounts", %{wardrik: wardrik, scope: scope} do
      assert %{"connections" => [%{"provider" => "mail", "connected" => false}]} =
               run!(scope, "connections.list", %{"owner" => "acme/@jon"})

      assert %{
               "provider" => "mail",
               "connected" => false,
               "authorization" => %{"url" => "https://mail.test/authorize?" <> _}
             } =
               run!(scope, "connections.connect", %{"owner" => "acme/@jon", "provider" => "mail"})

      hold(wardrik, "acme/@jon", "mail", "token")

      assert %{"connected" => true} =
               run!(scope, "connections.connect", %{"owner" => "acme/@jon", "provider" => "mail"})

      assert %{"connections" => [%{"connected" => true}]} =
               run!(scope, "connections.list", %{"owner" => "acme/@jon"})

      assert %{"provider" => "mail", "connected" => true} =
               run!(scope, "connections.disconnect", %{
                 "owner" => "acme/@jon",
                 "provider" => "mail"
               })

      assert %{"connections" => [%{"connected" => false}]} =
               run!(scope, "connections.list", %{"owner" => "acme/@jon"})

      assert "wardrik.secret.removed" in types(scope)

      assert refused(scope, "connections.connect", %{
               "owner" => "acme/@jon",
               "provider" => "asana"
             }) == :not_found
    end
  end

  describe "secrets" do
    test "seals, lists and removes an owner's secrets, never answering a value", %{
      wardrik: wardrik,
      scope: scope
    } do
      {:ok, _vsn} =
        WardrikVault.put(Wardrik.vault(wardrik), %Principal{id: "acme"}, "mail", "t",
          kind: :grant
        )

      assert run!(scope, "secrets.put", %{
               "owner" => "acme",
               "name" => "GITHUB_TOKEN",
               "value" => "ghp_1"
             }) == nil

      assert %{
               "secrets" => [%{"name" => "GITHUB_TOKEN", "kind" => "secret"}, %{"name" => "mail"}]
             } =
               run!(scope, "secrets.list", %{"owner" => "acme"})

      assert Wardrik.fetch_secret(wardrik, "acme", "GITHUB_TOKEN") == {:ok, "ghp_1"}
      assert %{"secrets" => []} = run!(scope, "secrets.list", %{"owner" => "acme/@jon"})

      assert run!(scope, "secrets.delete", %{"owner" => "acme", "name" => "GITHUB_TOKEN"}) == nil
      assert run!(scope, "secrets.delete", %{"owner" => "acme", "name" => "GITHUB_TOKEN"}) == nil

      secrets = Enum.filter(types(scope), &String.starts_with?(&1, "wardrik.secret."))
      assert secrets == ~w(wardrik.secret.stored wardrik.secret.removed wardrik.secret.removed)

      assert {:ok, [%Wardrik.Secret{name: "mail", kind: :grant}]} =
               Wardrik.Secrets.list(scope, owner: "acme")

      assert Wardrik.Secrets.put(scope, "DEPLOY", owner: "deployment", value: "d") == :ok
    end
  end

  describe "servers" do
    test "adds, lists and removes an owner's servers", %{wardrik: wardrik, scope: scope} do
      server = %{
        "owner" => "acme",
        "name" => "docs",
        "url" => "https://docs.test/mcp",
        "auth" => %{"none" => %{}}
      }

      assert %{"server" => "docs", "connected" => true} = run!(scope, "mcp_servers.add", server)
      assert refused(scope, "mcp_servers.add", server) == :conflict

      assert %{
               "servers" => [
                 %{"name" => "docs", "url" => "https://docs.test/mcp", "auth" => "none"}
               ]
             } =
               run!(scope, "mcp_servers.list", %{"owner" => "acme"})

      assert "acme:docs" in WardrikMCP.servers(Wardrik.mcp(wardrik))

      assert %{"name" => "docs"} =
               run!(scope, "mcp_servers.remove", %{"owner" => "acme", "server" => "docs"})

      refute "acme:docs" in WardrikMCP.servers(Wardrik.mcp(wardrik))
      assert %{"servers" => []} = run!(scope, "mcp_servers.list", %{"owner" => "acme"})

      assert refused(scope, "mcp_servers.remove", %{"owner" => "acme", "server" => "docs"}) ==
               :not_found

      assert ["wardrik.server.added", "wardrik.server.removed"] = types(scope)
    end

    test "reaches a server with a secret its owner keeps", %{wardrik: wardrik, scope: scope} do
      server = %{
        "owner" => "acme",
        "name" => "crm",
        "url" => "https://crm.test/mcp",
        "auth" => %{"secret" => %{"name" => "crm-key"}}
      }

      assert refused(scope, "mcp_servers.add", server) == :invalid_request

      hold(wardrik, "acme", "crm-key", "s3cret")
      assert %{"server" => "crm", "connected" => true} = run!(scope, "mcp_servers.add", server)
    end

    test "registers with a server's own sign-in, and says where each person signs in", %{
      wardrik: wardrik,
      scope: scope
    } do
      server = %{
        "owner" => "acme",
        "name" => "crm",
        "url" => "https://crm.test/mcp",
        "auth" => %{"oauth" => %{"scopes" => ["read"]}}
      }

      assert %{"server" => "crm", "connected" => false, "authorization" => %{"url" => url}} =
               run!(scope, "mcp_servers.add", server)

      query = URI.decode_query(URI.parse(url).query)
      assert %{"client_id" => "registered", "scope" => "read"} = query

      assert %{"name" => "crm", "auth" => "oauth"} =
               run!(scope, "mcp_servers.remove", %{"owner" => "acme", "server" => "crm"})

      refute "acme:crm" in WardrikOAuth.providers(Wardrik.oauth(wardrik))
    end

    test "offers an owner's server signed in to in a browser among their accounts, signed in as them",
         %{wardrik: wardrik, scope: scope} do
      server = %{
        "owner" => "acme",
        "name" => "crm",
        "url" => "https://crm.test/mcp",
        "auth" => %{"oauth" => %{"scopes" => ["read"]}}
      }

      assert %{"connected" => false, "authorization" => %{"url" => _url}} =
               run!(scope, "mcp_servers.add", server)

      assert %{"connections" => connections} =
               run!(scope, "connections.list", %{"owner" => "acme"})

      assert %{"provider" => "crm", "connected" => false} in connections

      assert %{"provider" => "crm", "connected" => false, "authorization" => %{"url" => _again}} =
               run!(scope, "connections.connect", %{"owner" => "acme", "provider" => "crm"})

      hold(wardrik, "acme", "acme:crm", "token")

      assert %{"provider" => "crm", "connected" => true} =
               run!(scope, "connections.connect", %{"owner" => "acme", "provider" => "crm"})

      assert %{"provider" => "crm", "connected" => true} =
               run!(scope, "connections.disconnect", %{"owner" => "acme", "provider" => "crm"})

      assert %{"connections" => connections} =
               run!(scope, "connections.list", %{"owner" => "acme"})

      assert %{"provider" => "crm", "connected" => false} in connections
      refute Enum.any?(connections, &(&1["provider"] == "acme:crm"))
    end

    test "signs in with an owner's own OAuth app, its client secret read from their vault", %{
      wardrik: wardrik,
      scope: scope
    } do
      hold(wardrik, "acme", "CRM_APP_SECRET", "app-secret")

      server = %{
        "owner" => "acme",
        "name" => "crm",
        "url" => "https://crm.test/mcp",
        "auth" => %{
          "oauth" => %{
            "authorization_endpoint" => "https://crm-auth.test/authorize",
            "token_endpoint" => "https://crm-auth.test/token",
            "client_id" => "acme-app",
            "client_secret" => %{"name" => "CRM_APP_SECRET"},
            "client_auth" => "basic",
            "scopes" => ["read"]
          }
        }
      }

      assert %{"connected" => false, "authorization" => %{"url" => url}} =
               run!(scope, "mcp_servers.add", server)

      assert "https://crm-auth.test/authorize?" <> query = url
      assert %{"client_id" => "acme-app", "scope" => "read"} = URI.decode_query(query)
    end

    test "refuses an owner's OAuth app whose secret they don't hold, or that names no client", %{
      scope: scope
    } do
      app = %{"issuer" => "https://auth.test", "client_id" => "acme-app"}
      server = %{"owner" => "acme", "name" => "crm", "url" => "https://crm.test/mcp"}

      missing = Map.put(app, "client_secret", %{"name" => "NOPE"})

      assert {:error, %Wardrik.Error{message: "acme holds no secret NOPE."}} =
               Wardrik.run(
                 scope,
                 "mcp_servers.add",
                 Map.put(server, "auth", %{"oauth" => missing})
               )

      unnamed = Map.delete(missing, "client_id")

      assert refused(scope, "mcp_servers.add", Map.put(server, "auth", %{"oauth" => unnamed})) ==
               :invalid_request
    end

    test "reaches a server Wardrik started with from the orgs it serves alone" do
      wardrik = %{Wardrik.new(name: :served) | mcp: [docs: [orgs: ["acme"]], wiki: []]}

      assert Wardrik.MCPTools.served(wardrik, "acme/@maria/notes") == ["docs", "wiki"]
      assert Wardrik.MCPTools.served(wardrik, "globex/triage") == ["wiki"]
    end

    test "gives a person's agents their own servers first, then their org's", %{
      wardrik: wardrik,
      scope: scope
    } do
      mcp = Wardrik.mcp(wardrik)

      for owner <- ["acme", "acme/@maria"], name <- ["docs"] do
        run!(scope, "mcp_servers.add", %{
          "owner" => owner,
          "name" => name,
          "url" => "https://docs.test/mcp",
          "auth" => %{"none" => %{}}
        })
      end

      run!(scope, "mcp_servers.add", %{
        "owner" => "acme",
        "name" => "wiki",
        "url" => "https://wiki.test/mcp",
        "auth" => %{"none" => %{}}
      })

      assert MCPTools.picked(mcp, "acme/@maria/notes", names: ["docs"]) == ["acme/@maria:docs"]
      assert MCPTools.picked(mcp, "acme/triage", names: ["docs"]) == ["acme:docs"]
      assert MCPTools.picked(mcp, "acme/@maria/notes", names: ["nope"]) == []

      assert Enum.sort(MCPTools.picked(mcp, "acme/@maria/notes", all: true)) == [
               "acme/@maria:docs",
               "acme:wiki"
             ]

      assert MCPTools.picked(mcp, "acme/triage", all: true) |> Enum.sort() == [
               "acme:docs",
               "acme:wiki"
             ]
    end

    test "names a server before it's added, as missing", %{scope: scope} do
      run!(scope, "agent.define", %{
        "agent" => "acme/@maria/notes",
        "model" => "anthropic:claude-haiku-4-5",
        "tools" => ["linear/*", "servers/*"]
      })

      assert %{"missing" => ["linear/*"]} =
               run!(scope, "agent.definition", %{"agent" => "acme/@maria/notes"})
    end
  end

  test "lets a reader list, but not add or connect", %{wardrik: wardrik} do
    reader =
      Wardrik.as(wardrik, "acme/@maria", [
        Statement.new(roles: [:reader], resources: ["acme/@maria/*"])
      ])

    assert %{"servers" => []} = run!(reader, "mcp_servers.list", %{"owner" => "acme/@maria"})

    server = %{
      "owner" => "acme/@maria",
      "name" => "docs",
      "url" => "https://docs.test/mcp",
      "auth" => %{"none" => %{}}
    }

    assert refused(reader, "mcp_servers.add", server) == :forbidden
    assert refused(reader, "mcp_servers.list", %{"owner" => "acme"}) == :not_found
  end
end
