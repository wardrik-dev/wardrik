defmodule WardrikDaemon.ResolverTest do
  use ExUnit.Case, async: false

  import WardrikDaemon.Test

  alias Wardrik.Resolved
  alias Wardrik.Resolver.Request
  alias WardrikCore.Principal

  setup context do
    context = dirs(context)

    write(context, "config.yaml", """
    org: platform
    http: {port: #{free_port()}}
    defaults: {model: #{model()}}
    mcp:
      stripe: {url: "http://127.0.0.1:1/stripe"}
      github: {url: "http://127.0.0.1:1/github"}
      search: {url: "http://127.0.0.1:1/search"}
    notify:
      targets:
        audit: {webhook: {url: "http://127.0.0.1:1/hook"}}
    orgs:
      "*": {mcp: [search], policy: base}
      payments: {mcp: [stripe], notify: [audit], policy: strict}
      growth: {mcp: [github]}
    """)

    write(context, "policies/base.yaml", "budget: {usd: 50.0, per: month}\n")
    write(context, "policies/strict.yaml", "deny: [stripe/refund]\n")
    start_daemon(context)
  end

  defp resolve(context, id),
    do: Wardrik.Resolver.resolve(Wardrik.Instance.fetch!(context.wardrik), %Request{agent: id})

  test "gives an agent its org's servers and targets, never another org's", context do
    assert {WardrikDaemon.Resolver, _opts} = Wardrik.Instance.fetch!(context.wardrik).resolver

    assert {:ok, %Resolved{servers: servers, notify: notify}} =
             resolve(context, "payments/@ana/refunds")

    assert servers == %{"stripe" => "stripe", "search" => "search"}
    assert notify == %{"audit" => "audit"}

    assert {:ok, %Resolved{servers: servers, notify: notify}} = resolve(context, "growth/leads")
    assert servers == %{"github" => "github", "search" => "search"}
    assert notify == %{}
  end

  test "reaches what its owner, its org and the deployment added, and nothing another org did",
       context do
    for owner <- ["growth", "payments/@ana"] do
      {:ok, _server} =
        Wardrik.run(context.admin, "mcp_servers.add", %{
          "owner" => owner,
          "name" => "crm",
          "url" => "http://127.0.0.1:1/crm",
          "auth" => %{"none" => %{}}
        })
    end

    assert {:ok, %Resolved{servers: %{"crm" => "payments/@ana:crm"}}} =
             resolve(context, "payments/@ana/refunds")

    assert {:ok, %Resolved{servers: servers}} = resolve(context, "payments/@bo/refunds")
    refute Map.has_key?(servers, "crm")

    assert {:ok, %Resolved{servers: %{"crm" => "growth:crm"}}} =
             resolve(context, "growth/@cy/leads")
  end

  test "acts for the agent's owner: its person, or its org", context do
    assert {:ok, %Resolved{principal: %Principal{id: "payments/@ana"}}} =
             resolve(context, "payments/@ana/refunds")

    assert {:ok, %Resolved{principal: %Principal{id: "payments"}}} =
             resolve(context, "payments/refunds/C1-1696.1234")
  end

  test "holds an agent to every org's policy, then its org's, and to the budget they pool",
       context do
    assert {:ok, %Resolved{policy: [base, strict], middleware: [{WardrikDaemon.Ceiling, held}]}} =
             resolve(context, "payments/refunds")

    assert base.budget == nil
    assert strict.name == "strict"
    assert held.org == "payments"
    assert [%WardrikDaemon.Ceiling{name: "base"}] = held.ceilings
  end

  test "resolves nothing for an org config.yaml doesn't declare, or an ID the daemon doesn't name",
       context do
    assert {:error, %Wardrik.Error{type: :not_found, message: "There's no org globex here" <> _}} =
             resolve(context, "globex/leads")

    for id <- ["../payments/refunds", "payments", "payments/a/b/c"] do
      assert {:error, %Wardrik.Error{type: :not_found}} = resolve(context, id)
    end
  end
end
