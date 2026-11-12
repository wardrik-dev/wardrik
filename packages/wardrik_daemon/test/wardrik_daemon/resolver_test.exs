defmodule WardrikDaemon.ResolverTest do
  use ExUnit.Case, async: false

  import WardrikDaemon.Test

  alias Wardrik.Resolved
  alias Wardrik.Resolver.Request
  alias WardrikCore.Principal
  alias WardrikDaemon.AgentRecords

  setup context do
    context = dirs(context)

    write(context, "config.yaml", """
    org: platform
    allow_private_urls: true
    http: {port: #{free_port()}}
    defaults: {model: #{model()}}
    mcp:
      stripe: {url: "http://127.0.0.1:1/stripe"}
      github: {url: "http://127.0.0.1:1/github"}
      search: {url: "http://127.0.0.1:1/search"}
    notify:
      targets:
        audit: {webhook: {url: "http://127.0.0.1:1/hook"}}
    channels:
      slack: {type: slack, signing_secret: s, client_id: "1.2", client_secret: c}
      team: {type: slack, token: xoxb-team, signing_secret: s}
    workspace:
      shared:
        agent:ledger: {read: [agent:refunds], write: [agent:ana-refunds]}
    orgs:
      "*": {mcp: [search], channels: [team], policy: base}
      payments: {mcp: [stripe], notify: [audit], policy: strict}
      growth: {mcp: [github]}
    """)

    write(context, "policies/base.yaml", "budget: {usd: 50.0, per: month}\n")
    write(context, "policies/strict.yaml", "deny: [stripe/refund]\n")
    start_daemon(context)
  end

  defp resolve(context, owner, name), do: resolve(context, recorded(context, owner, name))

  defp resolve(context, id),
    do: Wardrik.Resolver.resolve(Wardrik.Instance.fetch!(context.wardrik), %Request{agent: id})

  defp recorded(context, owner, name) do
    case AgentRecords.named(context.daemon_store, WardrikDaemon.Owners.org(owner), name) do
      {:ok, record} ->
        record.id

      :error ->
        {:ok, record} =
          AgentRecords.create(context.daemon_store, owner: owner, name: name, source: :api)

        record.id
    end
  end

  test "gives an agent its org's servers and targets, never another org's", context do
    assert {WardrikDaemon.Resolver, _opts} = Wardrik.Instance.fetch!(context.wardrik).resolver

    assert {:ok, %Resolved{servers: servers, notify: notify}} =
             resolve(context, "payments/@ana", "ana-refunds")

    assert servers == %{"stripe" => "stripe", "search" => "search"}
    assert notify == %{"audit" => "audit"}

    assert {:ok, %Resolved{servers: servers, notify: notify}} =
             resolve(context, "growth", "leads")

    assert servers == %{"github" => "github", "search" => "search"}
    assert notify == %{}
  end

  test "reaches what its owner, its org and the deployment added, and nothing another org did",
       context do
    {WardrikDaemon.Resolver, daemon} = Wardrik.Instance.fetch!(context.wardrik).resolver
    server = %{"name" => "crm", "url" => "http://127.0.0.1:1/crm", "auth" => %{"none" => %{}}}

    for owner <- ["growth", "payments/@ana"],
        do: {:ok, _added} = WardrikDaemon.Servers.add(daemon, {owner, server}, nil)

    assert {:ok, %Resolved{servers: %{"crm" => "payments/@ana:crm"}}} =
             resolve(context, "payments/@ana", "ana-refunds")

    assert {:ok, %Resolved{servers: servers}} = resolve(context, "payments/@bo", "bo-refunds")
    refute Map.has_key?(servers, "crm")

    assert {:ok, %Resolved{servers: %{"crm" => "growth:crm"}}} =
             resolve(context, "growth/@cy", "cy-leads")
  end

  test "acts for the agent's owner: its person, or its org", context do
    assert {:ok, %Resolved{principal: %Principal{id: "payments/@ana"}}} =
             resolve(context, "payments/@ana", "ana-refunds")

    assert {:ok, %Resolved{principal: %Principal{id: "payments"}}} =
             resolve(context, "payments", "refunds")
  end

  test "holds an agent to every org's policy, then its org's, and to the budget they pool",
       context do
    assert {:ok, %Resolved{policy: [base, strict], middleware: [{WardrikDaemon.Ceiling, held}]}} =
             resolve(context, "payments", "refunds")

    assert base.budget == nil
    assert strict.name == "strict"
    assert held.org == "payments"
    assert [%WardrikDaemon.Ceiling{name: "base"}] = held.ceilings
  end

  test "resolves nothing for an org config.yaml doesn't declare, or an ID the daemon didn't mint",
       context do
    assert {:error, %Wardrik.Error{type: :not_found, message: "There's no org globex here" <> _}} =
             resolve(context, "globex", "leads")

    for id <- ["payments/refunds", "payments", "agt_01JF8X5RQ2M3V9ZK0B7Y4T6WHN"] do
      assert {:error, %Wardrik.Error{type: :not_found}} = resolve(context, id)
    end
  end

  test "posts each channel's notices in the owner's workspace, then its org's, never another org's",
       context do
    {:ok, {adapter, opts}} = Wardrik.Operations.Channels.fetch(context.wardrik, "slack")
    slack = WardrikChannel.channel(adapter, opts)

    assert {:ok, %Resolved{channels: channels}} = resolve(context, "payments/@ana", "ana-refunds")
    assert channels == %{"team" => "*"}

    for {workspace, owner} <- [{"T1", "payments"}, {"T2", "payments/@ana"}, {"T3", "growth"}] do
      installation = %Wardrik.Channel.Installation{
        channel: "slack",
        workspace: workspace,
        owner: owner,
        token: "xoxb-#{workspace}"
      }

      :ok = WardrikChannel.Channel.install(slack, installation)
    end

    assert {:ok, %Resolved{channels: %{"slack" => "T2"}}} =
             resolve(context, "payments/@ana", "ana-refunds")

    assert {:ok, %Resolved{channels: %{"slack" => "T1"}}} =
             resolve(context, "payments/@bo", "bo-refunds")

    assert {:ok, %Resolved{channels: %{"slack" => "T1"}}} =
             resolve(context, "payments", "refunds")

    assert {:ok, %Resolved{channels: %{"slack" => "T3"}}} = resolve(context, "growth", "leads")
  end

  test "mounts exactly the workspaces config.yaml shares with the agent, by name in its org",
       context do
    ledger = recorded(context, "payments", "ledger")

    assert {:ok, %Resolved{workspaces: %{^ledger => :read} = read}} =
             resolve(context, "payments", "refunds")

    assert map_size(read) == 1

    assert {:ok, %Resolved{workspaces: %{^ledger => :write}}} =
             resolve(context, "payments/@ana", "ana-refunds")

    for {owner, name} <- [{"payments/@bo", "bo-refunds"}, {"growth", "leads"}] do
      assert {:ok, %Resolved{workspaces: none}} = resolve(context, owner, name)
      assert none == %{}
    end

    growth = recorded(context, "growth", "ledger")

    assert {:ok, %Resolved{workspaces: workspaces}} = resolve(context, "growth", "refunds")
    assert workspaces == %{growth => :read}
  end
end
