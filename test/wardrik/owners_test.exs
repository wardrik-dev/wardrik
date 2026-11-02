defmodule Wardrik.OwnersTest do
  use ExUnit.Case, async: false

  import Wardrik.Test.Wardrik

  alias WardrikCore.Principal
  alias WardrikVault.Secret

  setup {Req.Test, :set_req_test_to_shared}

  setup context do
    test = self()
    Req.Test.stub(__MODULE__, &authorization_server(&1, test))

    wardrik =
      Wardrik.new(
        authorizer: {Wardrik.Test.Allow, []},
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

  # A server's own sign-in, as the app that serves it adds one: named by its key, `owner:name`.
  defp server_app(wardrik, owner, name) do
    :ok =
      Wardrik.Operations.Providers.added(wardrik,
        owner: owner,
        name: owner <> ":" <> name,
        called: name,
        authorization_endpoint: "https://#{name}.test/authorize",
        token_endpoint: "https://#{name}.test/token",
        client_id: "wardrik"
      )
  end

  describe "server sign-ins" do
    test "offers an owner's server signed in to in a browser among their accounts, signed in as them",
         %{wardrik: wardrik, scope: scope} do
      server_app(wardrik, "acme", "crm")

      assert %{"connections" => connections} =
               run!(scope, "connections.list", %{"owner" => "acme"})

      assert %{"provider" => "crm", "connected" => false} in connections

      assert %{"provider" => "crm", "connected" => false, "authorization" => %{"url" => url}} =
               run!(scope, "connections.connect", %{"owner" => "acme", "provider" => "crm"})

      assert {:error, :wrong_principal} = signed_in(wardrik, url, "acme/@mallory")
      assert {:ok, "acme:crm"} = signed_in(wardrik, url, "acme")

      assert %{"provider" => "crm", "connected" => true} =
               run!(scope, "connections.connect", %{"owner" => "acme", "provider" => "crm"})

      assert %{"provider" => "crm", "connected" => true} =
               run!(scope, "connections.disconnect", %{"owner" => "acme", "provider" => "crm"})

      assert %{"connections" => connections} =
               run!(scope, "connections.list", %{"owner" => "acme"})

      assert %{"provider" => "crm", "connected" => false} in connections
      refute Enum.any?(connections, &(&1["provider"] == "acme:crm"))
    end

    test "offers a person the servers that serve them, each signed in to as themselves", %{
      wardrik: wardrik,
      scope: scope
    } do
      server_app(wardrik, "acme", "crm")
      server_app(wardrik, "deployment", "mail2")
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

    test "gives a person's own server's sign-in before their org's of the same name", %{
      wardrik: wardrik,
      scope: scope
    } do
      server_app(wardrik, "acme", "crm")
      server_app(wardrik, "acme/@maria", "crm")

      assert %{"authorization" => %{"url" => url}} =
               run!(scope, "connections.connect", %{"owner" => "acme/@maria", "provider" => "crm"})

      assert {:ok, "acme/@maria:crm"} = signed_in(wardrik, url, "acme/@maria")
    end

    test "names a server, not its key, where its own sign-in fails", %{
      wardrik: wardrik,
      scope: scope
    } do
      params = [owner: "acme", name: "acme:docs", called: "docs"]
      params = params ++ [authorization_params: %{"scope" => "read"}]

      assert {:error, %Wardrik.Error{message: "docs can't be signed in with: " <> _}} =
               Wardrik.Operations.Providers.added(wardrik, params)

      assert %{"connections" => connections} =
               run!(scope, "connections.list", %{"owner" => "acme"})

      refute Enum.any?(connections, &(&1["provider"] == "docs"))
    end
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

      :ok =
        seal(wardrik, {"acme", "GOOGLE_SECRET"}, "s3cret", :client_secret)

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
      server_app(wardrik, "acme", "crm")
      hold(wardrik, "acme", "acme:crm", "token")
      :ok = seal(wardrik, {"acme", "CRM_KEY"}, "secret")

      for owner <- ["acme/@maria", "globex", "globex/@lee", "deployment"] do
        assert %{"connections" => connections} =
                 run!(scope, "connections.list", %{"owner" => owner})

        refute %{"provider" => "crm", "connected" => true} in connections
        refute Enum.any?(connections, &(&1["provider"] =~ ":"))
      end

      vault = Wardrik.vault(wardrik)

      for owner <- ["acme/@maria", "globex", "deployment"], name <- ["acme:crm", "CRM_KEY"] do
        assert WardrikVault.lookup(vault, %Principal{id: owner}, name) == {:error, :not_found}
      end
    end
  end

  test "lets a reader list, but not add or connect", %{wardrik: wardrik} do
    reader = limited(wardrik, "acme/@maria", roles: [:reader], owners: ["acme/@maria"])

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
      limited(wardrik, "acme/@maria", roles: [:reader, :definer], owners: ["acme/@maria"])

    assert %{"name" => "notes"} =
             run!(definer, "providers.add", app("acme/@maria", "notes", "notes.test"))

    assert %{"name" => "notes"} =
             run!(definer, "providers.remove", %{"owner" => "acme/@maria", "provider" => "notes"})

    assert refused(definer, "providers.add", app("acme", "notes", "notes.test")) == :not_found
  end
end
