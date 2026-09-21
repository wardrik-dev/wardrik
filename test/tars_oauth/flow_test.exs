defmodule TarsOAuth.FlowTest do
  use TarsOAuth.Case, async: false

  defp provider(opts \\ []) do
    Provider.new(:github, Keyword.merge([resource: resource(), scopes: ~w(repo)], opts))
  end

  defp client(opts \\ []) do
    Client.new(
      Keyword.merge(
        [
          name: "Tars",
          document_url: "https://tars.dev/oauth/client",
          redirect_uri: redirect_uri(),
          req_options: [plug: {Req.Test, TarsOAuth.Stub}]
        ],
        opts
      )
    )
  end

  defp discover(opts \\ []) do
    stub_server(opts)
    configure(providers: [github: [resource: resource()]])

    {:ok, metadata} =
      Metadata.discover(resource(), req_options: [plug: {Req.Test, TarsOAuth.Stub}])

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
                 req_options: [plug: {Req.Test, TarsOAuth.Stub}]
               )

      assert metadata.issuer == "https://auth.example.com"
      refute_receive {:oauth, "GET", "/.well-known/oauth-protected-resource/mcp", _body}
    end

    test "reads the metadata URL out of a WWW-Authenticate challenge" do
      header =
        ~s(Bearer realm="mcp", resource_metadata="https://mcp.example.com/.well-known/oauth-protected-resource")

      assert {:ok, url} = Metadata.from_challenge(header)
      assert url =~ "oauth-protected-resource"
    end

    test "a resource that publishes nothing is an error, not a crash" do
      Req.Test.stub(TarsOAuth.Stub, fn conn -> Plug.Conn.resp(conn, 404, "no") end)

      assert {:error, {:metadata_unavailable, _url, 404}} =
               Metadata.discover(resource(), req_options: [plug: {Req.Test, TarsOAuth.Stub}])
    end
  end

  describe "register/3" do
    test "uses a client_id the deployment registered by hand" do
      metadata = discover(cimd: true, register: true)

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

    test "presents its metadata document where the server takes one" do
      metadata = discover(cimd: true, register: true)

      assert {:ok, registered} = Flow.register(metadata, client(), provider())

      assert registered.how == :cimd
      assert registered.client_id == "https://tars.dev/oauth/client"
      refute_receive {:oauth, "POST", "/register", _body}
    end

    test "registers dynamically where the server does not take a document" do
      metadata = discover(register: true)

      assert {:ok, registered} = Flow.register(metadata, client(), provider())

      assert registered.how == :dynamic
      assert registered.client_id == "registered-id"
      assert registered.client_secret == "registered-secret"

      assert_receive {:oauth, "POST", "/register", body}
      assert JSON.decode!(body)["client_name"] == "Tars"
      assert JSON.decode!(body)["redirect_uris"] == [redirect_uri()]
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
      assert params["client_id"] == "https://tars.dev/oauth/client"
      assert params["redirect_uri"] == redirect_uri()
      assert params["code_challenge"] == challenge
      assert params["code_challenge_method"] == "S256"
      assert params["state"] == "st"
      assert params["scope"] == "repo"
      assert params["resource"] == resource()
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
                 req_options: [plug: {Req.Test, TarsOAuth.Stub}]
               )

      assert token.access_token == "at_first"
      assert token.refresh_token == "rt_first"
      assert token.scope == "repo"
      assert token.expires_at > System.system_time(:second)

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

      assert {:error, {:token_refused, _status, _body}} =
               Flow.exchange(metadata, registered, "stale", "verifier",
                 req_options: [plug: {Req.Test, TarsOAuth.Stub}]
               )
    end

    test "renewing keeps the refresh token where the server sends none back" do
      metadata = discover(cimd: true)
      {:ok, registered} = Flow.register(metadata, client(), provider())
      {:ok, first} = Token.from_response(token())

      stub_server(cimd: true, token: %{"access_token" => "at_second", "expires_in" => 3600})

      assert {:ok, renewed} =
               Flow.refresh(metadata, registered, first,
                 req_options: [plug: {Req.Test, TarsOAuth.Stub}]
               )

      assert renewed.access_token == "at_second"
      assert renewed.refresh_token == "rt_first"

      assert_receive {:oauth, "POST", "/token", body}
      assert URI.decode_query(body)["grant_type"] == "refresh_token"
    end
  end

  describe "the client's own identity" do
    test "the document it serves is the client_id it presents" do
      document = Client.document(client())

      assert document["client_id"] == "https://tars.dev/oauth/client"
      assert document["client_name"] == "Tars"
      assert document["redirect_uris"] == [redirect_uri()]
      assert document["grant_types"] == ["authorization_code", "refresh_token"]
    end

    test "a registration body is the same thing without the id" do
      registration = Client.registration(client())

      refute Map.has_key?(registration, "client_id")
      assert registration["client_name"] == "Tars"
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
