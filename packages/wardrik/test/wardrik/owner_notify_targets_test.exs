defmodule Wardrik.OwnerNotifyTargetsTest do
  use ExUnit.Case, async: false

  import Wardrik.Test.Wardrik

  alias Wardrik.Authorizer.Request
  alias Wardrik.Notify.OwnedWebhook
  alias Wardrik.Operations.NotifyTargets
  alias Wardrik.Principal

  # Gives each agent of Ana the targets the test names.
  defmodule Routes do
    @behaviour Wardrik.Resolver

    @impl Wardrik.Resolver
    def resolve(_request, notify),
      do: {:ok, %Wardrik.Resolved{principal: %Principal{id: "ana"}, notify: notify}}
  end

  setup context do
    store_name = :"store #{context.test}"
    store = Wardrik.Test.Store.new(store_name)

    # Anyone may use the deployment's targets, Ana acme's too, and nobody globex's.
    decide = fn
      %Request{action: "notify_target.use", resource: {_, "deployment"}} -> :ok
      %Request{action: "notify_target.use", principal: %{id: "ana"}, resource: {_, "acme"}} -> :ok
      %Request{action: "notify_target.use"} -> {:error, :forbidden}
      _request -> :ok
    end

    wardrik =
      Wardrik.new(
        authorizer: {Wardrik.Test.Authorizer, test: self(), decide: decide},
        resolver: {Routes, Map.get(context, :routes, %{})},
        name: :"wardrik #{context.test}",
        store: store,
        vault_keys: [Wardrik.Vault.generate_key()],
        egress: &Wardrik.Egress.any/1,
        notify: [targets: [audit: {Wardrik.Test.Told, test: self()}]]
      )

    start_supervised!({Wardrik.Store, store})
    start_supervised!({Wardrik, wardrik})
    %{wardrik: wardrik, scope: owner(wardrik)}
  end

  defp add(scope, owner, name, extra \\ %{}) do
    input = %{"owner" => owner, "name" => name, "url" => "https://hooks.test/" <> name}
    Wardrik.run(scope, "notify_targets.add", Map.merge(input, extra))
  end

  test "adds, lists and removes an owner's webhooks, and lists the deployment's", %{
    scope: scope
  } do
    assert {:error, %Wardrik.Error{message: "acme holds no secret HOOK" <> _}} =
             add(scope, "acme", "ops", %{"secret" => %{"name" => "HOOK"}})

    {:ok, nil} =
      Wardrik.run(scope, "secrets.put", %{
        "owner" => "acme",
        "name" => "HOOK",
        "value" => "s3cret",
        "purpose" => "signing_secret"
      })

    assert {:ok, %{"name" => "ops", "secret" => %{"name" => "HOOK"}}} =
             add(scope, "acme", "ops", %{"secret" => %{"name" => "HOOK"}})

    assert {:error, %Wardrik.Error{type: :conflict}} = add(scope, "acme", "ops")
    assert {:error, %Wardrik.Error{type: :conflict}} = add(scope, "deployment", "audit")

    assert {:ok, [%Wardrik.NotifyTarget{name: "ops", url: "https://hooks.test/ops"}]} =
             Wardrik.NotifyTargets.list(scope, "acme")

    assert {:ok, [%Wardrik.NotifyTarget{name: "audit", source: :config, kind: "told"}]} =
             Wardrik.NotifyTargets.list(scope, "deployment")

    assert {:error, %Wardrik.Error{type: :invalid_request}} =
             Wardrik.NotifyTargets.remove(scope, owner: "deployment", name: "audit")

    assert {:ok, %Wardrik.NotifyTarget{name: "ops"}} =
             Wardrik.NotifyTargets.remove(scope, owner: "acme", name: "ops")

    assert {:error, %Wardrik.Error{type: :not_found}} =
             Wardrik.NotifyTargets.remove(scope, owner: "acme", name: "ops")
  end

  test "routes an agent to its own target, else one it may use, else the deployment's", %{
    wardrik: wardrik,
    scope: scope
  } do
    for {owner, name} <- [{"ana", "ops"}, {"acme", "ops"}, {"acme", "sales"}, {"globex", "pager"}],
        do: {:ok, _added} = add(scope, owner, name)

    assert %{
             "ops" => {OwnedWebhook, ops},
             "sales" => {OwnedWebhook, sales},
             "audit" => "audit"
           } = reached = NotifyTargets.reached(wardrik, %Principal{id: "ana"})

    assert ops[:owner] == "ana" and sales[:owner] == "acme"
    refute Map.has_key?(reached, "pager")
    assert NotifyTargets.reached(wardrik, %Principal{id: "bob"}) == %{"audit" => "audit"}
  end

  @tag routes: %{"pager" => {OwnedWebhook, url: "https://hooks.test/pager", owner: "globex"}}
  test "refuses an agent a target another owner keeps unless it may use it", %{scope: scope} do
    assert {:error, %Wardrik.Error{message: "ana may not use globex's notify target pager."}} =
             Wardrik.run(scope, "agent.define", %{
               "agent" => "acme/triage",
               "model" => "anthropic:claude-haiku-4-5"
             })
  end

  test "skips a notice to a webhook whose owner holds no secret to sign it with", %{
    wardrik: wardrik
  } do
    notice = %Wardrik.Notice{
      kind: :failed,
      agent: "acme/triage",
      reason: "boom",
      at: DateTime.utc_now()
    }

    opts = [
      wardrik: wardrik.name,
      target: "ops",
      url: "https://hooks.test/ops",
      owner: "acme",
      secret: "HOOK"
    ]

    assert {:skip, "but acme holds no secret HOOK to sign it with"} =
             OwnedWebhook.deliver(notice, opts)
  end
end
