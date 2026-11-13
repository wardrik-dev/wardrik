defmodule Wardrik.ConnectionsTest do
  use ExUnit.Case, async: false

  alias Wardrik.Authorizer.Request
  alias Wardrik.Vault.Secret
  alias WardrikCore.Principal

  setup context do
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
end
