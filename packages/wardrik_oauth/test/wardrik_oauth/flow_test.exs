defmodule WardrikOAuth.FlowTest do
  use WardrikOAuth.Case, async: false

  setup do
    configure(providers: [])
  end

  defp provider(opts \\ []) do
    Provider.new(:github, Keyword.merge([resource: resource(), scopes: ~w(repo)], opts))
  end

  defp client(opts \\ []) do
    Client.new(
      Keyword.merge(
        [
          name: "Wardrik",
          document_url: "https://wardrik.dev/oauth/client",
          redirect_uri: redirect_uri(),
          req_options: [plug: {Req.Test, WardrikOAuth.Stub}]
        ],
        opts
      )
    )
  end

  defp discover(opts \\ []) do
    {issuer, opts} = Keyword.pop(opts, :issuer)
    stub_server(opts)
    configure(providers: [github: [resource: resource()]])

    {:ok, metadata} =
      Metadata.discover(resource(),
        issuer: issuer,
        req_options: [plug: {Req.Test, WardrikOAuth.Stub}]
      )

    metadata
  end

  describe "discovery" do
    test "walks resource metadata to the authorization server" do
      metadata = discover()

      assert metadata.issuer == "https://auth.example.com"
      assert metadata.authorization_endpoint == "https://auth.example.com/authorize"
      assert metadata.token_endpoint == "https://auth.example.com/token"
      assert metadata.resource == resource()

      assert_receive {:oauth, "GET", "/.well-known/oauth-protected-resource/mcp", _body}
      assert_receive {:oauth, "GET", "/.well-known/oauth-authorization-server", _body}
    end

    test "falls back to OpenID configuration where there is no OAuth metadata" do
      metadata = discover(oidc_only: true)

      assert metadata.token_endpoint == "https://auth.example.com/token"
      assert_receive {:oauth, "GET", "/.well-known/openid-configuration", _body}
    end

    test "an issuer given in advance skips the resource leg" do
      stub_server()

      assert {:ok, metadata} =
               Metadata.discover(resource(),
                 issuer: "https://auth.example.com",
                 req_options: [plug: {Req.Test, WardrikOAuth.Stub}]
               )

      assert metadata.issuer == "https://auth.example.com"
      refute_receive {:oauth, "GET", "/.well-known/oauth-protected-resource/mcp", _body}
    end

    test "takes a resource named with or without its trailing slash" do
      metadata = discover(resource_named: resource() <> "/")
      assert metadata.issuer == "https://auth.example.com"
    end

    test "refuses resource metadata that names another resource" do
      stub_server(resource_named: "https://elsewhere.example.com/mcp")

      assert {:error, {:resource_mismatch, _asked, "https://elsewhere.example.com/mcp"}} =
               Metadata.discover(resource())
    end

    test "refuses metadata that names another issuer, or none" do
      stub_server(issuer_named: "https://evil.example.com")

      assert {:error, {:issuer_mismatch, "https://auth.example.com", "https://evil.example.com"}} =
               Metadata.discover(resource())

      stub_server(issuer_named: nil)

      assert {:error, {:metadata_incomplete, "https://auth.example.com"}} =
               Metadata.discover(resource())
    end

    test "refuses a discovered endpoint that is not https" do
      stub_server(endpoints: %{"token_endpoint" => "http://auth.example.com/token"})

      assert {:error, {:insecure_url, "http://auth.example.com/token"}} =
               Metadata.discover(resource())
    end

    test "refuses an authorization server the resource names on a private address" do
      stub_server(as: "https://internal.example.com")

      assert {:error, {:private_address, "internal.example.com"}} = Metadata.discover(resource())
    end

    test "trusts an issuer the deployment named, and its endpoints, wherever they are" do
      stub_server(as: "https://internal.example.com")

      assert {:ok, metadata} =
               Metadata.discover(resource(), issuer: "https://internal.example.com")

      assert metadata.trust == :operator
      assert metadata.token_endpoint == "https://internal.example.com/token"
    end

    test "follows no redirect" do
      stub_server(redirect_prm: true)

      assert {:error, {:metadata_unavailable, _url, 302}} = Metadata.discover(resource())
      refute_receive {:oauth, "GET", "/prm", _body}
    end

    test "says whether the server takes a SHA-256 PKCE challenge" do
      assert Metadata.pkce?(discover())
      refute Metadata.pkce?(discover(no_pkce: true))
    end

    test "reads the metadata URL out of a WWW-Authenticate challenge" do
      header =
        ~s(Bearer realm="mcp", resource_metadata="https://mcp.example.com/.well-known/oauth-protected-resource")

      assert {:ok, url} = Metadata.from_challenge(header)
      assert url =~ "oauth-protected-resource"
    end

    test "a resource that publishes nothing is an error, not a crash" do
      Req.Test.stub(WardrikOAuth.Stub, fn conn -> Plug.Conn.resp(conn, 404, "no") end)

      assert {:error, {:metadata_unavailable, _url, 404}} =
               Metadata.discover(resource(), req_options: [plug: {Req.Test, WardrikOAuth.Stub}])
    end
  end

  describe "register/3" do
    test "uses a client_id the deployment registered by hand" do
      metadata = discover(cimd: true, register: true, issuer: "https://auth.example.com")

      assert {:ok, registered} =
               Flow.register(
                 metadata,
                 client(),
                 provider(client_id: "Iv1.hand", client_secret: "s")
               )

      assert registered.how == :static
      assert registered.client_id == "Iv1.hand"
      assert registered.client_secret == "s"
    end

    test "sends a client secret only to an issuer the deployment named" do
      metadata = discover(cimd: true, register: true)
      assert metadata.trust == :discovered

      assert {:error, {:client_secret_needs_issuer, "github"}} =
               Flow.register(
                 metadata,
                 client(),
                 provider(client_id: "Iv1.hand", client_secret: "s")
               )

      assert {:ok, %{how: :static, client_secret: nil}} =
               Flow.register(metadata, client(), provider(client_id: "Iv1.public"))
    end

    test "presents its metadata document where the server takes one" do
      metadata = discover(cimd: true, register: true)

      assert {:ok, registered} = Flow.register(metadata, client(), provider())

      assert registered.how == :cimd
      assert registered.client_id == "https://wardrik.dev/oauth/client"
      refute_receive {:oauth, "POST", "/register", _body}
    end

    test "registers a public client dynamically where the server does not take a document" do
      metadata = discover(register: true)

      assert {:ok, registered} = Flow.register(metadata, client(), provider())

      assert registered.how == :dynamic
      assert registered.client_id == "registered-id"
      # The stub hands back a secret; a public client keeps none.
      assert registered.client_secret == nil

      assert_receive {:oauth, "POST", "/register", body}
      assert JSON.decode!(body)["client_name"] == "Wardrik"
      assert JSON.decode!(body)["redirect_uris"] == [redirect_uri()]
    end

    test "uses a client registered before instead of registering again" do
      metadata = discover(register: true)

      known = %{
        client_id: "kept-id",
        client_secret: nil,
        redirect_uri: redirect_uri(),
        how: :dynamic
      }

      assert {:ok, ^known} = Flow.register(metadata, client(), provider(), known: known)
      refute_receive {:oauth, "POST", "/register", _body}
    end

    test "a server offering no way to register says so" do
      metadata = discover()

      assert {:error, {:no_registration, "https://auth.example.com"}} =
               Flow.register(metadata, client(), provider())
    end
  end

  describe "authorize_url/4" do
    test "carries PKCE, the state, the scopes and the resource" do
      metadata = discover(cimd: true)
      {:ok, registered} = Flow.register(metadata, client(), provider())
      {_verifier, challenge} = Flow.pkce()

      url = Flow.authorize_url(metadata, registered, challenge, state: "st", scopes: ~w(repo))
      params = params_of(url)

      assert String.starts_with?(url, "https://auth.example.com/authorize?")
      assert params["response_type"] == "code"
      assert params["client_id"] == "https://wardrik.dev/oauth/client"
      assert params["redirect_uri"] == redirect_uri()
      assert params["code_challenge"] == challenge
      assert params["code_challenge_method"] == "S256"
      assert params["state"] == "st"
      assert params["scope"] == "repo"
      assert params["resource"] == resource()
    end

    test "carries a provider's params, which cannot change what the flow sets itself" do
      metadata = discover(cimd: true)
      {:ok, registered} = Flow.register(metadata, client(), provider())
      {_verifier, challenge} = Flow.pkce()

      params =
        metadata
        |> Flow.authorize_url(registered, challenge,
          state: "st",
          params: %{"access_type" => "offline", "prompt" => "consent", "state" => "theirs"}
        )
        |> params_of()

      assert params["access_type"] == "offline"
      assert params["prompt"] == "consent"
      assert params["state"] == "st"
    end

    test "a challenge is the SHA-256 of its verifier, and each pair is new" do
      {verifier, challenge} = Flow.pkce()

      assert challenge == :sha256 |> :crypto.hash(verifier) |> Base.url_encode64(padding: false)
      refute Flow.pkce() == {verifier, challenge}
    end
  end

  describe "exchange/5 and refresh/4" do
    test "trades a code for a token, with the verifier and the resource" do
      metadata = discover(cimd: true)
      {:ok, registered} = Flow.register(metadata, client(), provider())

      assert {:ok, token} =
               Flow.exchange(metadata, registered, "the-code", "the-verifier",
                 req_options: [plug: {Req.Test, WardrikOAuth.Stub}]
               )

      assert token.access_token == "at_first"
      assert token.refresh_token == "rt_first"
      assert token.scope == "repo"
      assert token.expires_at > System.system_time(:second)

      # Bound to where it came from.
      assert token.issuer == "https://auth.example.com"
      assert token.token_endpoint == "https://auth.example.com/token"
      assert token.client_id == "https://wardrik.dev/oauth/client"
      assert token.resource == resource()

      assert_receive {:oauth, "POST", "/token", body}
      sent = URI.decode_query(body)
      assert sent["grant_type"] == "authorization_code"
      assert sent["code"] == "the-code"
      assert sent["code_verifier"] == "the-verifier"
      assert sent["resource"] == resource()
    end

    test "a refusal is an error, not a token" do
      metadata = discover(cimd: true)
      {:ok, registered} = Flow.register(metadata, client(), provider())
      stub_server(cimd: true, token: %{"error" => "invalid_grant"})

      assert {:error, {:token_refused, "invalid_grant", nil}} =
               Flow.exchange(metadata, registered, "stale", "verifier",
                 req_options: [plug: {Req.Test, WardrikOAuth.Stub}]
               )
    end

    test "renewing keeps the refresh token where the server sends none back" do
      metadata = discover(cimd: true)
      {:ok, registered} = Flow.register(metadata, client(), provider())
      {:ok, first} = Token.from_response(token())
      first = Token.bind(first, metadata, registered)

      stub_server(cimd: true, token: %{"access_token" => "at_second", "expires_in" => 3600})

      assert {:ok, renewed} =
               Flow.refresh(first, req_options: [plug: {Req.Test, WardrikOAuth.Stub}])

      assert renewed.access_token == "at_second"
      assert renewed.refresh_token == "rt_first"
      assert renewed.token_endpoint == first.token_endpoint

      assert_receive {:oauth, "POST", "/token", body}
      sent = URI.decode_query(body)
      assert sent["grant_type"] == "refresh_token"
      assert sent["client_id"] == "https://wardrik.dev/oauth/client"
      assert sent["resource"] == resource()
      refute Map.has_key?(sent, "client_secret")
    end

    test "a token that does not know where it came from is not renewed" do
      {:ok, unbound} = Token.from_response(token())
      assert {:error, :not_renewable} = Flow.refresh(unbound)
    end
  end

  describe "the client's own identity" do
    test "the document it serves is the client_id it presents" do
      document = Client.document(client())

      assert document["client_id"] == "https://wardrik.dev/oauth/client"
      assert document["client_name"] == "Wardrik"
      assert document["redirect_uris"] == [redirect_uri()]
      assert document["grant_types"] == ["authorization_code", "refresh_token"]
    end

    test "a registration body is the same thing without the id" do
      registration = Client.registration(client())

      refute Map.has_key?(registration, "client_id")
      assert registration["client_name"] == "Wardrik"
    end
  end

  describe "a token" do
    test "says nothing when inspected" do
      {:ok, token} = Token.from_response(token())

      refute inspect(token) =~ "at_first"
      refute inspect(token) =~ "rt_first"
      assert inspect(token) =~ "redacted"
    end

    test "survives being written down and read back" do
      {:ok, token} = Token.from_response(token())

      assert {:ok, ^token} = token |> Token.encode() |> Token.decode()
    end

    test "is stale before it expires, not after" do
      now = System.system_time(:second)
      {:ok, token} = Token.from_response(token(%{"expires_in" => 10}))

      refute Token.fresh?(token, now)
      assert Token.fresh?(%{token | expires_at: now + 600}, now)
      assert Token.fresh?(%{token | expires_at: nil}, now)
    end
  end
end
