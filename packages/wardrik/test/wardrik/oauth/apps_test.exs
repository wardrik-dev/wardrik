defmodule Wardrik.OAuth.AppsTest do
  use ExUnit.Case, async: false

  import Wardrik.Test.Wardrik

  alias Wardrik.Authorizer.Request
  alias Wardrik.OAuth.Apps
  alias Wardrik.Principal

  @app %{
    "authorization_endpoint" => "https://linear.test/authorize",
    "token_endpoint" => "https://linear.test/token",
    "client_id" => "acme-client"
  }

  setup context do
    store_name = :"store #{context.test}"
    store = Wardrik.Test.Store.new(store_name)

    # Anyone may use the deployment's apps, Ana acme's too, and nobody globex's.
    decide = fn
      %Request{action: "provider.use", resource: {:provider, "deployment"}} ->
        :ok

      %Request{action: "provider.use", principal: %{id: "ana"}, resource: {:provider, "acme"}} ->
        :ok

      %Request{action: "provider.use"} ->
        {:error, :forbidden}

      _request ->
        :ok
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
              client_id: "deployment-client",
              client_secret: "s3cret"
            ]
          ]
        ]
      )

    start_supervised!({Wardrik.Store, store})
    start_supervised!({Wardrik, wardrik})
    %{wardrik: wardrik, scope: owner(wardrik)}
  end

  defp add(scope, owner, name, app \\ @app),
    do: Wardrik.run(scope, "providers.add", Map.merge(app, %{"owner" => owner, "name" => name}))

  test "keeps, lists and removes an owner's apps, and lists the deployment's it declares", %{
    scope: scope
  } do
    assert {:ok, %{"owner" => "acme", "name" => "linear", "source" => "runtime"}} =
             add(scope, "acme", "linear")

    assert {:error, %Wardrik.Error{type: :conflict}} = add(scope, "acme", "linear")

    assert {:ok, [%Wardrik.OAuthApp{name: "linear", client_id: "acme-client"}]} =
             Wardrik.Providers.list(scope, "acme")

    assert {:ok, [%Wardrik.OAuthApp{name: "google", source: :config}]} =
             Wardrik.Providers.list(scope, "deployment")

    assert {:error, %Wardrik.Error{type: :invalid_request}} =
             Wardrik.Providers.remove(scope, owner: "deployment", name: "google")

    assert {:ok, %Wardrik.OAuthApp{name: "linear"}} =
             Wardrik.Providers.remove(scope, owner: "acme", name: "linear")

    assert %{"events" => [%{"type" => "wardrik.provider.added"}, %{"type" => removed}]} =
             run!(scope, "audit.list", %{})

    assert removed == "wardrik.provider.removed"
  end

  test "signs in with the one app a reference names, where its owner's app may be used", %{
    wardrik: wardrik,
    scope: scope
  } do
    {:ok, _added} = add(scope, "acme", "linear")
    {:ok, _added} = add(scope, "globex", "linear")
    ana = %Principal{id: "ana"}

    assert {:ok, %{url: "https://linear.test/authorize?" <> query}} =
             Wardrik.sign_in(wardrik.name, "acme:linear", ana)

    assert URI.decode_query(query)["client_id"] == "acme-client"

    assert {:error, :not_found} = Wardrik.sign_in(wardrik.name, "globex:linear", ana)
    assert {:error, :not_found} = Wardrik.sign_in(wardrik.name, "linear", ana)

    assert {:ok, %{url: "https://google.test/authorize?" <> _query}} =
             Wardrik.sign_in(wardrik.name, "deployment:google", %Principal{id: "globex"})
  end

  test "chooses an owner's own app, then the one another owner lets it use, then the deployment's",
       %{wardrik: wardrik, scope: scope} do
    {:ok, _added} = add(scope, "acme", "google")
    {:ok, _added} = add(scope, "ana", "google")

    assert %{owner: "ana"} = Apps.chosen(wardrik, %Principal{id: "ana"}, "google")
    assert %{owner: "deployment"} = Apps.chosen(wardrik, %Principal{id: "bob"}, "google")
    assert nil == Apps.chosen(wardrik, %Principal{id: "bob"}, "linear")

    {:ok, _added} = add(scope, "acme", "linear")
    assert %{owner: "acme"} = Apps.chosen(wardrik, %Principal{id: "ana"}, "linear")

    offered = Apps.offered(wardrik, %Principal{id: "ana"})
    assert ["google", "linear"] = Enum.map(offered, & &1.name)
  end
end
