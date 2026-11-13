defmodule Wardrik.OwnerSecretsTest do
  use ExUnit.Case, async: false

  import Wardrik.Test.Wardrik

  alias Wardrik.Authorizer.Request

  setup context do
    store = Wardrik.Test.Store.new(:"store #{context.test}")
    test = self()

    decide = fn
      %Request{resource: {:secret, "globex"}} -> {:error, :forbidden}
      _request -> :ok
    end

    wardrik =
      Wardrik.new(
        authorizer: {Wardrik.Test.Authorizer, test: test, decide: decide},
        resolver: {Wardrik.Test.Owned, :"wardrik #{context.test}"},
        name: :"wardrik #{context.test}",
        store: store,
        vault_keys: Map.get(context, :vault_keys, [Wardrik.Vault.generate_key()])
      )

    start_supervised!({Wardrik.Store, store})
    start_supervised!({Wardrik, wardrik})
    :ok = Wardrik.EventLog.subscribe(Wardrik.events(wardrik), :all)
    %{wardrik: wardrik, scope: owner(wardrik)}
  end

  test "seals, lists and removes an owner's secrets, never answering a value", %{scope: scope} do
    sealed = %{"owner" => "acme/@jon", "name" => "CRM_KEY", "value" => "s3cret"}
    assert run!(scope, "secrets.put", Map.put(sealed, "purpose", "header")) == nil

    assert_received {:authorize, %Request{action: "secret.put", resource: {:secret, "acme/@jon"}}}

    assert {:ok, [%Wardrik.SealedSecret{name: "CRM_KEY", purpose: :header}]} =
             Wardrik.Secrets.list(scope, "acme/@jon")

    assert %{"secrets" => []} = run!(scope, "secrets.list", %{"owner" => "acme"})

    assert :ok = Wardrik.Secrets.delete(scope, owner: "acme/@jon", name: "CRM_KEY")
    assert {:ok, []} = Wardrik.Secrets.list(scope, "acme/@jon")

    assert %{"events" => [stored, removed]} = run!(scope, "audit.list", %{})
    assert %{"type" => "wardrik.secret.stored", "data" => %{"owner" => "acme/@jon"}} = stored
    assert %{"type" => "wardrik.secret.removed", "subject" => "secrets/CRM_KEY"} = removed
  end

  test "asks the authorizer about the owner, and refuses what it refuses", %{scope: scope} do
    assert refused(scope, "secrets.list", %{"owner" => "globex"}) == :forbidden

    assert refused(scope, "secrets.put", %{
             "owner" => "acme",
             "name" => "X",
             "value" => "v",
             "purpose" => "nonsense"
           }) == :invalid_request
  end

  @tag vault_keys: []
  test "says a vault without keys can't seal", %{scope: scope} do
    assert {:error, %Wardrik.Error{type: :not_supported}} =
             Wardrik.Secrets.put(scope, owner: "acme", name: "X", value: "v", purpose: "api_key")
  end
end
