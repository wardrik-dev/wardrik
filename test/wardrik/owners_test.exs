defmodule Wardrik.OwnersTest do
  use ExUnit.Case, async: false

  import Wardrik.Test.Wardrik

  alias Wardrik.MCPTools
  alias Wardrik.Statement
  alias WardrikCore.Principal
  alias WardrikVault.Secret

  setup {Req.Test, :set_req_test_to_shared}

  setup context do
    test = self()
    Req.Test.stub(__MODULE__, &authorization_server(&1, test))

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
              client_id: "wardrik",
              client_secret: "mail-secret"
            ]
          ]
        ]
      )

    start_supervised!({Wardrik, wardrik})
    %{wardrik: wardrik, scope: owner(wardrik)}
  end

  defp authorization_server(conn, test) do
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

      {"POST", "/token"} ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        basic = Plug.Conn.get_req_header(conn, "authorization")
        send(test, {:exchanged, conn.host, URI.decode_query(body), basic})
        Req.Test.json(conn, %{"access_token" => "token", "expires_in" => 3600})
    end
  end

  defp signed_in(wardrik, url, owner) do
    state = URI.decode_query(URI.parse(url).query)["state"]
    params = %{"state" => state, "code" => "c0de"}

    with {:ok, %{provider: provider}} <-
           WardrikOAuth.finish(Wardrik.oauth(wardrik), params, as: %Principal{id: owner}),
         do: {:ok, provider}
  end

  defp app(owner, name, host, fields \\ %{}) do
    Map.merge(
      %{
        "owner" => owner,
        "name" => name,
        "authorization_endpoint" => "https://#{host}/authorize",
        "token_endpoint" => "https://#{host}/token",
        "client_id" => "#{name}-app"
      },
      fields
    )
  end

  defp listed(scope, owner) do
    %{"providers" => providers} = run!(scope, "providers.list", %{"owner" => owner})
    Enum.map(providers, &{&1["owner"], &1["name"]})
  end

  defp hold(wardrik, owner, name, value, kind \\ :grant) do
    secret = %Secret{principal: %Principal{id: owner}, name: name, value: value}
    {:ok, _vsn} = WardrikVault.put(Wardrik.vault(wardrik), secret, kind: kind)
  end

  defp types(scope) do
    %{"events" => changes} = run!(scope, "audit.list", %{})
    Enum.map(changes, & &1["type"])
  end

  test "names the client a service shows people signing in as the Wardrik's oauth says", %{
    wardrik: wardrik
  } do
    {WardrikOAuth.Plug, %{oauth: oauth}} =
      Wardrik.sign_in_pages(wardrik, {Wardrik.HTTP, :nobody, []})

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
      secret = %Secret{principal: %Principal{id: "acme"}, name: "mail", value: "t"}
      {:ok, _vsn} = WardrikVault.put(Wardrik.vault(wardrik), secret, kind: :grant)

      assert run!(scope, "secrets.put", %{
               "owner" => "acme",
               "name" => "GITHUB_TOKEN",
               "value" => "ghp_1",
               "purpose" => "header"
             }) == nil

      assert %{
               "secrets" => [%{"name" => "GITHUB_TOKEN", "kind" => "header"}, %{"name" => "mail"}]
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

      assert Wardrik.Secrets.put(scope, "DEPLOY",
               owner: "deployment",
               value: "d",
               purpose: "api_key"
             ) == :ok
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

    test "reaches a server with a secret its owner keeps, read as each connection starts", %{
      wardrik: wardrik,
      scope: scope
    } do
      server = %{
        "owner" => "acme",
        "name" => "crm",
        "url" => Wardrik.Test.Headers.start("/acme"),
        "auth" => %{"secret" => %{"name" => "crm-key"}}
      }

      assert {:error, %Wardrik.Error{message: "acme holds no secret crm-key sealed as a header."}} =
               Wardrik.run(scope, "mcp_servers.add", server)

      :ok = Wardrik.put_secret(wardrik, "acme", "crm-key", "one", kind: :header)
      assert %{"server" => "crm", "connected" => true} = run!(scope, "mcp_servers.add", server)
      assert_receive {:authorization, "/acme", ["Bearer one"]}, 5_000

      stored =
        WardrikStore.get(WardrikStore.scope(wardrik.store, "wardrik_mcp"), "servers/acme:crm")

      assert {:streamable_http, http} = stored[:transport]
      assert http[:headers] == %{"authorization" => ["Bearer ", {:secret, "crm-key"}]}

      :ok = Wardrik.put_secret(wardrik, "acme", "crm-key", "two", kind: :header)
      assert_receive {:authorization, "/acme", ["Bearer two"]}, 5_000

      raw = %{
        server
        | "name" => "raw",
          "auth" => %{"secret" => %{"name" => "crm-key", "header" => "x-key", "scheme" => ""}}
      }

      run!(scope, "mcp_servers.add", raw)

      stored =
        WardrikStore.get(WardrikStore.scope(wardrik.store, "wardrik_mcp"), "servers/acme:raw")

      assert {:streamable_http, http} = stored[:transport]
      assert http[:headers] == %{"x-key" => {:secret, "crm-key"}}
    end

    test "reaches another org's server with that org's secret alone", %{
      wardrik: wardrik,
      scope: scope
    } do
      :ok = Wardrik.put_secret(wardrik, "acme", "crm-key", "acme's", kind: :header)

      server = %{
        "owner" => "globex",
        "name" => "crm",
        "url" => Wardrik.Test.Headers.start("/globex"),
        "auth" => %{"secret" => %{"name" => "crm-key"}}
      }

      assert {:error,
              %Wardrik.Error{message: "globex holds no secret crm-key sealed as a header."}} =
               Wardrik.run(scope, "mcp_servers.add", server)

      :ok = Wardrik.put_secret(wardrik, "globex", "crm-key", "globex's", kind: :header)
      run!(scope, "mcp_servers.add", server)
      assert_receive {:authorization, "/globex", ["Bearer globex's"]}, 5_000

      :ok = Wardrik.put_secret(wardrik, "acme", "crm-key", "acme's again", kind: :header)
      :ok = Wardrik.delete_secret(wardrik, "globex", "crm-key")
      refute_receive {:authorization, "/globex", _authorization}, 500
    end

    test "lists the servers an owner's agents reach, nearest first, with who holds each", %{
      wardrik: wardrik
    } do
      :ok = stop_supervised!(Wardrik)

      config = [
        docs: [
          transport:
            {:streamable_http,
             url: "https://docs.test/mcp", headers: %{"authorization" => {:secret, "DOCS"}}},
          orgs: ["acme"]
        ],
        wiki: [transport: {:streamable_http, url: "https://wiki.test/mcp"}, orgs: ["globex"]],
        git: [transport: {:stdio, command: "git-mcp-server"}, credential_name: "git"]
      ]

      wardrik = %{wardrik | mcp: config}
      start_supervised!({Wardrik, wardrik})
      scope = owner(wardrik)

      for {owner, name} <- [{"deployment", "search"}, {"acme", "crm"}, {"acme/@maria", "crm"}] do
        run!(scope, "mcp_servers.add", %{
          "owner" => owner,
          "name" => name,
          "url" => "https://#{name}.test/mcp",
          "auth" => %{"none" => %{}}
        })
      end

      listed = fn owner ->
        %{"servers" => servers} = run!(scope, "mcp_servers.list", %{"owner" => owner})
        Enum.map(servers, &{&1["owner"], &1["name"], &1["source"]})
      end

      assert listed.("acme/@maria") == [
               {"acme/@maria", "crm", "runtime"},
               {"deployment", "search", "runtime"},
               {"deployment", "docs", "config"},
               {"deployment", "git", "config"}
             ]

      assert listed.("globex") == [
               {"deployment", "search", "runtime"},
               {"deployment", "wiki", "config"},
               {"deployment", "git", "config"}
             ]

      assert %{"servers" => servers} =
               run!(scope, "mcp_servers.list", %{"owner" => "deployment"})

      assert Enum.map(servers, & &1["name"]) == ["search", "docs", "wiki", "git"]

      assert %{
               "owner" => "deployment",
               "name" => "docs",
               "source" => "config",
               "url" => "https://docs.test/mcp",
               "auth" => "secret"
             } in servers

      assert %{"owner" => "deployment", "name" => "git", "source" => "config", "auth" => "oauth"} in servers
      refute inspect(servers) =~ "DOCS"

      assert {:ok, [%Wardrik.MCPServer{owner: "acme/@maria", source: :runtime} | _rest]} =
               Wardrik.MCPServers.list(scope, owner: "acme/@maria")

      for {owner, name, type} <- [
            {"acme/@maria", "search", :not_found},
            {"acme", "docs", :not_found},
            {"deployment", "docs", :invalid_request},
            {"deployment", "nope", :not_found}
          ] do
        assert refused(scope, "mcp_servers.remove", %{"owner" => owner, "server" => name}) ==
                 type
      end

      assert {:error,
              %Wardrik.Error{message: "docs is an MCP server the deployment starts with."}} =
               Wardrik.run(scope, "mcp_servers.remove", %{
                 "owner" => "deployment",
                 "server" => "docs"
               })

      assert %{"owner" => "acme/@maria", "name" => "crm", "source" => "runtime"} =
               run!(scope, "mcp_servers.remove", %{"owner" => "acme/@maria", "server" => "crm"})

      assert {"acme", "crm", "runtime"} in listed.("acme/@maria")
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

      refute "acme:crm" in Enum.map(
               WardrikOAuth.providers(Wardrik.oauth(wardrik), "acme"),
               & &1.name
             )
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
      hold(wardrik, "acme", "CRM_APP_SECRET", "app-secret", :client_secret)

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

      assert [%WardrikOAuth.Provider{owner: "acme", client_secret: {:secret, "CRM_APP_SECRET"}}] =
               wardrik
               |> Wardrik.oauth()
               |> WardrikOAuth.providers("acme")
               |> Enum.filter(&(&1.name == "acme:crm"))

      assert {:error, :wrong_principal} = signed_in(wardrik, url, "acme/@mallory")
      assert {:ok, "acme:crm"} = signed_in(wardrik, url, "acme")
      assert_received {:exchanged, "crm-auth.test", %{"code" => "c0de"}, [first]}
      assert first == "Basic " <> Base.encode64("acme-app:app-secret")

      hold(wardrik, "acme", "CRM_APP_SECRET", "rotated", :client_secret)
      run!(scope, "connections.disconnect", %{"owner" => "acme", "provider" => "crm"})

      assert %{"authorization" => %{"url" => url}} =
               run!(scope, "connections.connect", %{"owner" => "acme", "provider" => "crm"})

      assert {:ok, "acme:crm"} = signed_in(wardrik, url, "acme")
      assert_received {:exchanged, "crm-auth.test", _form, [rotated]}
      assert rotated == "Basic " <> Base.encode64("acme-app:rotated")
    end

    test "signs in with an OAuth app the owner can use, connected once for every server naming it",
         %{wardrik: wardrik, scope: scope} do
      run!(scope, "providers.add", app("acme", "google", "google.test"))

      server = %{
        "owner" => "acme/@maria",
        "name" => "ads",
        "url" => "https://ads.test/mcp",
        "auth" => %{"oauth" => %{"provider" => "google"}}
      }

      assert %{"server" => "ads", "connected" => false, "authorization" => %{"url" => url}} =
               run!(scope, "mcp_servers.add", server)

      assert "https://google.test/authorize?" <> query = url
      assert %{"client_id" => "google-app"} = URI.decode_query(query)
      assert {:ok, "google"} = signed_in(wardrik, url, "acme/@maria")

      analytics = %{server | "name" => "analytics", "url" => "https://analytics.test/mcp"}

      assert %{"server" => "analytics", "connected" => true} =
               run!(scope, "mcp_servers.add", analytics)

      assert %{"connections" => connections} =
               run!(scope, "connections.list", %{"owner" => "acme/@maria"})

      assert %{"provider" => "google", "connected" => true} in connections
      refute Enum.any?(connections, &(&1["provider"] in ["ads", "analytics"]))

      assert %{"name" => "ads", "auth" => "oauth"} =
               run!(scope, "mcp_servers.remove", %{"owner" => "acme/@maria", "server" => "ads"})

      assert {"acme", "google"} in listed(scope, "acme/@maria")
      assert "google" in WardrikVault.names(Wardrik.vault(wardrik), %Principal{id: "acme/@maria"})

      for {owner, provider} <- [{"globex", "google"}, {"acme", "nope"}] do
        assert {:error, %Wardrik.Error{type: :invalid_request, message: message}} =
                 Wardrik.run(scope, "mcp_servers.add", %{
                   server
                   | "owner" => owner,
                     "auth" => %{"oauth" => %{"provider" => provider}}
                 })

        assert message == "#{owner} has no OAuth app #{provider}."
      end
    end

    test "refuses an owner's OAuth app whose secret they don't hold, or that names no client", %{
      scope: scope
    } do
      app = %{"issuer" => "https://auth.test", "client_id" => "acme-app"}
      server = %{"owner" => "acme", "name" => "crm", "url" => "https://crm.test/mcp"}

      missing = Map.put(app, "client_secret", %{"name" => "NOPE"})

      assert {:error,
              %Wardrik.Error{message: "acme holds no secret NOPE sealed as a client_secret."}} =
               Wardrik.run(
                 scope,
                 "mcp_servers.add",
                 Map.put(server, "auth", %{"oauth" => missing})
               )

      unnamed = Map.delete(missing, "client_id")

      assert refused(scope, "mcp_servers.add", Map.put(server, "auth", %{"oauth" => unnamed})) ==
               :invalid_request
    end

    test "names a server, not its key, where its own sign-in fails", %{
      wardrik: wardrik,
      scope: scope
    } do
      Req.Test.stub(__MODULE__, &Plug.Conn.send_resp(&1, 500, ""))

      server = %{
        "owner" => "acme",
        "name" => "crm",
        "url" => "https://crm.test/mcp",
        "auth" => %{"oauth" => %{"scopes" => ["read"]}}
      }

      assert {:error,
              %Wardrik.Error{type: :unavailable, message: "crm can't be signed in to now: " <> _}} =
               Wardrik.run(scope, "mcp_servers.add", server)

      assert {:error, %Wardrik.Error{message: "crm can't be signed in to now: " <> _}} =
               Wardrik.run(scope, "connections.connect", %{"owner" => "acme", "provider" => "crm"})

      params = [authorization_params: %{"scope" => "read"}]

      assert {:error, %Wardrik.Error{message: "crm can't be signed in with: " <> _}} =
               Wardrik.Operations.Providers.added(wardrik, "acme", "acme:crm", params, "crm")
    end

    test "reaches a server Wardrik started with from the orgs it serves alone", %{
      wardrik: wardrik
    } do
      wardrik = %{wardrik | mcp: [docs: [orgs: ["acme"]], wiki: []]}

      assert servers(wardrik, "acme/@maria/notes") == %{"docs" => "docs", "wiki" => "wiki"}
      assert servers(wardrik, "globex/triage") == %{"wiki" => "wiki"}
    end

    defp servers(wardrik, id) do
      {:ok, resolved} =
        Wardrik.Owners.Resolver.resolve(wardrik, %Wardrik.Resolver.Request{agent: id})

      resolved.servers
    end

    defp picked(wardrik, id, opts),
      do: MCPTools.picked(Wardrik.mcp(wardrik), servers(wardrik, id), opts)

    test "gives a person's agents their own servers first, then their org's", %{
      wardrik: wardrik,
      scope: scope
    } do
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

      assert picked(wardrik, "acme/@maria/notes", names: ["docs"]) == ["acme/@maria:docs"]
      assert picked(wardrik, "acme/triage", names: ["docs"]) == ["acme:docs"]
      assert picked(wardrik, "acme/@maria/notes", names: ["nope"]) == []

      assert Enum.sort(picked(wardrik, "acme/@maria/notes", all: true)) == [
               "acme/@maria:docs",
               "acme:wiki"
             ]

      assert picked(wardrik, "acme/triage", all: true) |> Enum.sort() == [
               "acme:docs",
               "acme:wiki"
             ]
    end

    test "gives every agent the deployment's servers, after its owners'", %{
      wardrik: wardrik,
      scope: scope
    } do
      for owner <- ["deployment", "acme"], name <- ["docs"] do
        run!(scope, "mcp_servers.add", %{
          "owner" => owner,
          "name" => name,
          "url" => "https://docs.test/mcp",
          "auth" => %{"none" => %{}}
        })
      end

      assert picked(wardrik, "acme/@maria/notes", names: ["docs"]) == ["acme:docs"]
      assert picked(wardrik, "globex/triage", names: ["docs"]) == ["deployment:docs"]
      assert picked(wardrik, "globex/triage", all: true) == ["deployment:docs"]
    end

    test "offers a person the servers that serve them, each signed in to as themselves", %{
      wardrik: wardrik,
      scope: scope
    } do
      for {owner, name} <- [{"acme", "crm"}, {"deployment", "mail2"}] do
        run!(scope, "mcp_servers.add", %{
          "owner" => owner,
          "name" => name,
          "url" => "https://#{name}.test/mcp",
          "auth" => %{"oauth" => %{}}
        })
      end

      hold(wardrik, "acme", "acme:crm", "the org's token")

      assert %{"connections" => connections} =
               run!(scope, "connections.list", %{"owner" => "acme/@maria"})

      assert %{"provider" => "crm", "connected" => false} in connections
      assert %{"provider" => "mail2", "connected" => false} in connections

      hold(wardrik, "acme/@maria", "acme:crm", "maria's token")

      assert %{"provider" => "crm", "connected" => true} =
               run!(scope, "connections.connect", %{"owner" => "acme/@maria", "provider" => "crm"})

      assert %{"connections" => connections} =
               run!(scope, "connections.list", %{"owner" => "globex"})

      refute Enum.any?(connections, &(&1["provider"] == "crm"))
      assert %{"provider" => "mail2", "connected" => false} in connections
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

  describe "providers" do
    test "lists an owner's OAuth apps, then those from further out, the nearest of each name", %{
      wardrik: wardrik,
      scope: scope
    } do
      hold(wardrik, "acme", "GOOGLE_SECRET", "s3cret", :client_secret)

      run!(scope, "providers.add", app("deployment", "google", "google.test"))

      run!(
        scope,
        "providers.add",
        app("acme", "google", "acme-google.test", %{
          "client_secret" => %{"name" => "GOOGLE_SECRET"},
          "client_auth" => "basic",
          "scopes" => ["ads"],
          "authorization_params" => %{"access_type" => "offline"}
        })
      )

      run!(scope, "providers.add", app("acme/@jon", "notes", "notes.test"))

      assert listed(scope, "acme/@jon") == [
               {"acme/@jon", "notes"},
               {"acme", "google"},
               {"deployment", "mail"}
             ]

      assert listed(scope, "globex") == [{"deployment", "google"}, {"deployment", "mail"}]

      assert %{"providers" => [_notes, google, mail]} =
               run!(scope, "providers.list", %{"owner" => "acme/@jon"})

      assert google == %{
               "owner" => "acme",
               "name" => "google",
               "source" => "runtime",
               "authorization_endpoint" => "https://acme-google.test/authorize",
               "token_endpoint" => "https://acme-google.test/token",
               "client_id" => "google-app",
               "client_secret" => %{"name" => "GOOGLE_SECRET"},
               "client_auth" => "basic",
               "scopes" => ["ads"],
               "flow" => "browser",
               "authorization_params" => %{"access_type" => "offline"}
             }

      assert %{"source" => "config", "client_id" => "wardrik"} = mail
      refute Map.has_key?(mail, "client_secret")

      refute inspect(run!(scope, "providers.list", %{"owner" => "acme"})) =~
               ~r/s3cret|mail-secret/

      assert {:ok, [%Wardrik.Provider{owner: "acme", client_secret: "GOOGLE_SECRET"} | _rest]} =
               Wardrik.Providers.list(scope, owner: "acme")
    end

    test "adds and removes an owner's own, which no other owner sees or removes", %{
      wardrik: wardrik,
      scope: scope
    } do
      google = app("acme", "google", "google.test")

      assert %{"owner" => "acme", "name" => "google", "source" => "runtime"} =
               run!(scope, "providers.add", google)

      assert refused(scope, "providers.add", google) == :conflict
      assert refused(scope, "providers.add", app("deployment", "mail", "mail.test")) == :conflict

      assert %{"owner" => "acme/@jon", "name" => "google"} =
               run!(scope, "providers.add", %{google | "owner" => "acme/@jon"})

      refute {"acme", "google"} in listed(scope, "globex")

      assert refused(scope, "providers.remove", %{"owner" => "globex", "provider" => "google"}) ==
               :not_found

      assert %{"owner" => "acme", "name" => "google", "client_id" => "google-app"} =
               run!(scope, "providers.remove", %{"owner" => "acme", "provider" => "google"})

      assert refused(scope, "providers.remove", %{"owner" => "acme", "provider" => "google"}) ==
               :not_found

      assert refused(scope, "providers.remove", %{"owner" => "deployment", "provider" => "mail"}) ==
               :invalid_request

      assert {"acme/@jon", "google"} in listed(scope, "acme/@jon")

      assert {:error,
              %Wardrik.Error{message: "acme holds no secret NOPE sealed as a client_secret."}} =
               Wardrik.run(
                 scope,
                 "providers.add",
                 Map.put(google, "client_secret", %{"name" => "NOPE"})
               )

      assert Enum.filter(types(scope), &String.starts_with?(&1, "wardrik.provider.")) ==
               ~w(wardrik.provider.added wardrik.provider.added wardrik.provider.removed)

      :ok = Wardrik.put_secret(wardrik, "acme", "GOOGLE_SECRET", "s3cret", kind: :client_secret)

      assert {:ok, %Wardrik.Provider{owner: "acme", client_secret: "GOOGLE_SECRET"}} =
               Wardrik.Providers.add(scope,
                 owner: "acme",
                 name: "google",
                 issuer: "https://accounts.google.com",
                 client_id: "google-app",
                 client_secret: %{name: "GOOGLE_SECRET"},
                 authorization_params: %{access_type: "offline"}
               )

      assert {:ok,
              %Wardrik.Provider{
                name: "google",
                authorization_params: %{"access_type" => "offline"}
              }} =
               Wardrik.Providers.remove(scope, "google", owner: "acme")
    end

    test "offers an org's OAuth app to its people, each signing in as themselves", %{
      wardrik: wardrik,
      scope: scope
    } do
      run!(scope, "providers.add", app("acme", "linear", "linear.test"))

      for person <- ["acme/@maria", "acme/@jon"] do
        assert %{"connections" => connections} =
                 run!(scope, "connections.list", %{"owner" => person})

        assert %{"provider" => "linear", "connected" => false} in connections
      end

      assert %{"connections" => connections} =
               run!(scope, "connections.list", %{"owner" => "globex/@lee"})

      refute Enum.any?(connections, &(&1["provider"] == "linear"))

      assert %{"authorization" => %{"url" => "https://linear.test/authorize?" <> _query = url}} =
               run!(scope, "connections.connect", %{
                 "owner" => "acme/@maria",
                 "provider" => "linear"
               })

      assert {:ok, "linear"} = signed_in(wardrik, url, "acme/@maria")
      assert_received {:exchanged, "linear.test", %{"client_id" => "linear-app"}, []}

      assert %{"connections" => connections} =
               run!(scope, "connections.list", %{"owner" => "acme/@maria"})

      assert %{"provider" => "linear", "connected" => true} in connections

      assert %{"connections" => connections} =
               run!(scope, "connections.list", %{"owner" => "acme/@jon"})

      assert %{"provider" => "linear", "connected" => false} in connections
    end
  end

  describe "isolation" do
    test "an owner's accounts and secrets reach no other owner, nearer or farther", %{
      wardrik: wardrik,
      scope: scope
    } do
      run!(scope, "mcp_servers.add", %{
        "owner" => "acme",
        "name" => "crm",
        "url" => "https://crm.test/mcp",
        "auth" => %{"oauth" => %{}}
      })

      hold(wardrik, "acme", "acme:crm", "token")
      :ok = Wardrik.put_secret(wardrik, "acme", "CRM_KEY", "secret")
      :ok = Wardrik.put_secret(wardrik, "deployment", "MAIL_KEY", "secret")

      for owner <- ["acme/@maria", "globex", "globex/@lee", "deployment"] do
        assert %{"connections" => connections} =
                 run!(scope, "connections.list", %{"owner" => owner})

        refute %{"provider" => "crm", "connected" => true} in connections
        refute Enum.any?(connections, &(&1["provider"] =~ ":"))

        assert %{"secrets" => secrets} = run!(scope, "secrets.list", %{"owner" => owner})
        names = Enum.map(secrets, & &1["name"])
        refute "CRM_KEY" in names
        refute "acme:crm" in names
        if owner != "deployment", do: refute("MAIL_KEY" in names)
      end

      vault = Wardrik.vault(wardrik)

      for owner <- ["acme/@maria", "globex", "deployment"], name <- ["acme:crm", "CRM_KEY"] do
        assert WardrikVault.lookup(vault, %Principal{id: owner}, name) == {:error, :not_found}
      end
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

    assert %{"providers" => [%{"name" => "mail"}]} =
             run!(reader, "providers.list", %{"owner" => "acme/@maria"})

    assert refused(reader, "providers.add", app("acme/@maria", "notes", "notes.test")) ==
             :forbidden

    assert refused(reader, "providers.remove", %{"owner" => "acme/@maria", "provider" => "mail"}) ==
             :forbidden

    assert refused(reader, "providers.list", %{"owner" => "acme"}) == :not_found
  end

  test "lets a definer add and remove their own OAuth apps, and no one else's", %{
    wardrik: wardrik
  } do
    definer =
      Wardrik.as(wardrik, "acme/@maria", [
        Statement.new(roles: [:reader, :definer], resources: ["acme/@maria/*"])
      ])

    assert %{"name" => "notes"} =
             run!(definer, "providers.add", app("acme/@maria", "notes", "notes.test"))

    assert %{"name" => "notes"} =
             run!(definer, "providers.remove", %{"owner" => "acme/@maria", "provider" => "notes"})

    assert refused(definer, "providers.add", app("acme", "notes", "notes.test")) == :not_found
  end
end
