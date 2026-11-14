defmodule Wardrik.ConnectionsTest do
  use ExUnit.Case, async: false
  use Mimic

  alias Wardrik.Authorizer.Request
  alias Wardrik.Principal
  alias Wardrik.Vault.Secret

  setup {Req.Test, :set_req_test_to_shared}

  setup context do
    Req.Test.stub(__MODULE__, fn conn ->
      Req.Test.json(conn, %{"access_token" => "linear_token", "expires_in" => 3600})
    end)

    store_name = :"store #{context.test}"
    store = Wardrik.Test.Store.new(store_name)

    # Ana may use acme's apps, and anyone the deployment's.
    decide = fn
      %Request{action: "provider.use", resource: {:provider, "deployment"}} -> :ok
      %Request{action: "provider.use", principal: %{id: "ana"}, resource: {_, "acme"}} -> :ok
      %Request{action: "provider.use"} -> {:error, :forbidden}
      _request -> :ok
    end

    wardrik =
      Wardrik.new(
        authorizer: {Wardrik.Test.Authorizer, test: self(), decide: decide},
        resolver: {Wardrik.Test.Owned, :"wardrik #{context.test}"},
        name: :"wardrik #{context.test}",
        store: store,
        vault_keys: [Wardrik.Vault.generate_key()],
        egress: &Wardrik.Egress.any/1,
        oauth: [
          page: "https://agents.test/oauth",
          req_options: [plug: {Req.Test, __MODULE__}],
          providers: [
            google: [
              authorization_endpoint: "https://google.test/authorize",
              token_endpoint: "https://google.test/token",
              client_id: "deployment-client"
            ]
          ]
        ]
      )

    start_supervised!({Wardrik.Store, store})
    start_supervised!({Wardrik, wardrik})

    admin = Wardrik.as(wardrik.name, "admin")

    {:ok, _app} =
      Wardrik.run(admin, "providers.add", %{
        "owner" => "acme",
        "name" => "linear",
        "authorization_endpoint" => "https://linear.test/authorize",
        "token_endpoint" => "https://linear.test/token",
        "client_id" => "acme-client"
      })

    %{
      wardrik: wardrik,
      ana: Wardrik.as(wardrik.name, "ana"),
      bob: Wardrik.as(wardrik.name, "bob")
    }
  end

  defp grant(wardrik, id, credential) do
    secret = %Secret{principal: %Principal{id: id}, name: credential, value: "grant"}
    vault = Wardrik.vault(wardrik)
    {:ok, _vsn} = Wardrik.Vault.put(vault, secret, kind: :grant)
  end

  test "offers each app the caller may sign in with, and says which they hold", %{
    wardrik: wardrik,
    ana: ana,
    bob: bob
  } do
    grant(wardrik, "ana", "acme:linear")

    assert {:ok,
            [
              %Wardrik.Connection{provider: "google", connected: false, signing_in: false},
              %Wardrik.Connection{provider: "linear", connected: true}
            ]} = Wardrik.Connections.list(ana)

    assert {:ok, [%Wardrik.Connection{provider: "google"}]} = Wardrik.Connections.list(bob)

    assert_received {:authorize,
                     %Request{action: "connection.read", resource: {:connection, "ana"}}}
  end

  test "starts a sign-in, says one is held, and forgets only the caller's own", %{
    wardrik: wardrik,
    ana: ana,
    bob: bob
  } do
    assert {:ok, %Wardrik.Connecting{connected: false, authorization: %{"url" => url}}} =
             Wardrik.Connections.connect(ana, "linear")

    assert "https://linear.test/authorize?" <> _query = url
    assert {:ok, [_google, %Wardrik.Connection{signing_in: true}]} = Wardrik.Connections.list(ana)

    grant(wardrik, "ana", "acme:linear")

    assert {:ok, %Wardrik.Connecting{connected: true}} =
             Wardrik.Connections.connect(ana, "linear")

    assert {:error, %Wardrik.Error{type: :not_found}} = Wardrik.Connections.connect(bob, "linear")

    assert {:error, %Wardrik.Error{type: :not_found}} =
             Wardrik.Connections.disconnect(bob, "google")

    assert :ok = Wardrik.Connections.disconnect(ana, "linear")

    assert {:error, %Wardrik.Error{type: :not_found}} =
             Wardrik.Connections.disconnect(ana, "linear")
  end

  test "lists a sign-in that ends while it reads as connected, not as ended", %{
    wardrik: wardrik,
    ana: ana
  } do
    {:ok, %Wardrik.Connecting{authorization: %{"url" => url}}} =
      Wardrik.Connections.connect(ana, "linear")

    %{"state" => state} =
      url
      |> URI.parse()
      |> Map.fetch!(:query)
      |> URI.decode_query()

    # The sign-in ends just after the first read of the store.
    stub(Wardrik.Store, :keys, &call_original(Wardrik.Store, :keys, [&1]))

    expect(Wardrik.Store, :keys, fn store ->
      keys = call_original(Wardrik.Store, :keys, [store])
      params = %{"state" => state, "code" => "c"}
      {:ok, _signed_in} = Wardrik.finish_sign_in(wardrik, params, as: ana.principal)
      keys
    end)

    assert {:ok, [_google, %Wardrik.Connection{provider: "linear"} = linear]} =
             Wardrik.Connections.list(ana)

    assert linear.connected or linear.signing_in
  end
end
