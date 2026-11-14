defmodule Wardrik.OwnerServersTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Wardrik.Test.Wardrik

  alias Wardrik.Authorizer.Request
  alias Wardrik.Operations.Servers
  alias Wardrik.Principal

  # Gives each agent of Ana the servers `Servers.reached/2` picks for her, or what the test says.
  defmodule Reach do
    @behaviour Wardrik.Resolver

    @impl Wardrik.Resolver
    def resolve(_request, %{name: name, servers: servers}) do
      wardrik = Wardrik.Instance.fetch!(name)
      ana = %Principal{id: "ana"}
      given = servers || Servers.reached(wardrik, ana)
      {:ok, %Wardrik.Resolved{principal: ana, servers: given}}
    end
  end

  setup context do
    store_name = :"store #{context.test}"
    store = Wardrik.Test.Store.new(store_name)
    name = :"wardrik #{context.test}"

    # Anyone may use the deployment's servers, Ana acme's too, and nobody globex's.
    decide = fn
      %Request{action: "mcp_server.use", resource: {:mcp_server, "deployment"}} -> :ok
      %Request{action: "mcp_server.use", principal: %{id: "ana"}, resource: {_, "acme"}} -> :ok
      %Request{action: "mcp_server.use"} -> {:error, :forbidden}
      _request -> :ok
    end

    oauth = if context[:oauth], do: [oauth: [page: "https://agents.test/oauth"]], else: []

    wardrik =
      Wardrik.new(
        [
          authorizer: {Wardrik.Test.Authorizer, test: self(), decide: decide},
          resolver: {Reach, %{name: name, servers: Map.get(context, :servers)}},
          name: name,
          store: store,
          vault_keys: [Wardrik.Vault.generate_key()],
          egress: &Wardrik.Egress.any/1,
          mcp: [wiki: [transport: {:streamable_http, url: "http://127.0.0.1:1/wiki"}]]
        ] ++ oauth
      )

    start_supervised!({Wardrik.Store, store})
    capture_log(fn -> start_supervised!({Wardrik, wardrik}) end)
    %{wardrik: wardrik, scope: owner(wardrik)}
  end

  defp add(scope, owner, name) do
    input = %{
      "owner" => owner,
      "name" => name,
      "url" => "http://127.0.0.1:1/" <> name,
      "auth" => %{"none" => %{}}
    }

    capture_log(fn -> send(self(), {:added, Wardrik.run(scope, "servers.add", input)}) end)
    assert_received {:added, added}
    added
  end

  test "adds, lists and removes an owner's servers, and lists the deployment's it starts with", %{
    wardrik: wardrik,
    scope: scope
  } do
    assert {:ok, %{"server" => "crm", "connected" => true}} = add(scope, "acme", "crm")
    assert {:error, %Wardrik.Error{type: :conflict}} = add(scope, "acme", "crm")
    assert {:error, %Wardrik.Error{type: :conflict}} = add(scope, "deployment", "wiki")
    mcp = Wardrik.mcp(wardrik)
    servers = Wardrik.MCP.Servers.all(mcp)
    assert Map.has_key?(servers, "acme:crm")

    assert {:ok, [%Wardrik.MCPServer{owner: "acme", name: "crm", source: :runtime}]} =
             Wardrik.Servers.list(scope, "acme")

    assert {:ok, [%Wardrik.MCPServer{name: "wiki", source: :config}]} =
             Wardrik.Servers.list(scope, "deployment")

    assert {:error, %Wardrik.Error{type: :invalid_request}} =
             Wardrik.Servers.remove(scope, owner: "deployment", name: "wiki")

    assert {:ok, %Wardrik.MCPServer{name: "crm"}} =
             Wardrik.Servers.remove(scope, owner: "acme", name: "crm")

    remaining = Wardrik.MCP.Servers.all(mcp)
    refute Map.has_key?(remaining, "acme:crm")

    assert %{"events" => [%{"type" => "wardrik.server.added"}, %{"type" => removed}]} =
             run!(scope, "audit.list", %{})

    assert removed == "wardrik.server.removed"
  end

  test "reaches an agent's own server, else one it may use, else the deployment's", %{
    wardrik: wardrik,
    scope: scope
  } do
    for {owner, name} <- [{"ana", "crm"}, {"acme", "crm"}, {"acme", "docs"}, {"globex", "notes"}],
        do: {:ok, _added} = add(scope, owner, name)

    assert Servers.reached(wardrik, %Principal{id: "ana"}) == %{
             "crm" => "ana:crm",
             "docs" => "acme:docs",
             "wiki" => "wiki"
           }

    assert Servers.reached(wardrik, %Principal{id: "bob"}) == %{"wiki" => "wiki"}

    {:ok, _agent} =
      Wardrik.Agent.define(scope, "acme/triage", model: "anthropic:claude-haiku-4-5")

    assert %{"servers" => [crm, docs, wiki]} =
             run!(scope, "agent.resolved", %{"agent" => "acme/triage"})

    assert %{"name" => "crm", "server" => "crm", "owner" => "ana"} = crm
    assert %{"name" => "docs", "server" => "docs", "owner" => "acme"} = docs
    assert %{"name" => "wiki", "server" => "wiki", "owner" => "deployment"} = wiki
  end

  test "signs in with a sealed header, an OAuth app the owner may use, or the server's own app",
       %{scope: scope} do
    server = fn name, auth ->
      %{"owner" => "acme", "name" => name, "url" => "http://127.0.0.1:1/" <> name, "auth" => auth}
    end

    run = fn input ->
      capture_log(fn -> send(self(), {:ran, Wardrik.run(scope, "servers.add", input)}) end)
      assert_received {:ran, ran}
      ran
    end

    secret = %{"secret" => %{"name" => "CRM_KEY"}}

    crm = server.("crm", secret)
    assert {:error, %Wardrik.Error{message: "acme holds no secret CRM_KEY" <> _}} = run.(crm)

    {:ok, nil} =
      Wardrik.run(scope, "secrets.put", %{
        "owner" => "acme",
        "name" => "CRM_KEY",
        "value" => "s3cret",
        "purpose" => "header"
      })

    assert {:ok, %{"connected" => true}} = run.(crm)

    issues = server.("issues", %{"oauth" => %{"provider" => "linear"}})
    assert {:error, %Wardrik.Error{type: :not_supported}} = run.(issues)
  end

  @tag oauth: true
  test "signs in with an OAuth app the owner may use, or one made for the server", %{
    scope: scope,
    wardrik: wardrik
  } do
    endpoints = %{
      "authorization_endpoint" => "https://auth.test/authorize",
      "token_endpoint" => "https://auth.test/token",
      "client_id" => "acme-client"
    }

    {:ok, _app} =
      Wardrik.run(
        scope,
        "providers.add",
        Map.merge(endpoints, %{"owner" => "acme", "name" => "linear"})
      )

    server = fn name, auth ->
      %{"owner" => "acme", "name" => name, "url" => "http://127.0.0.1:1/" <> name, "auth" => auth}
    end

    run = fn input ->
      capture_log(fn -> send(self(), {:ran, Wardrik.run(scope, "servers.add", input)}) end)
      assert_received {:ran, ran}
      ran
    end

    issues = server.("issues", %{"oauth" => %{"provider" => "linear"}})

    assert {:ok, %{"connected" => false, "authorization" => %{"url" => "https://auth.test" <> _}}} =
             run.(issues)

    other = server.("other", %{"oauth" => %{"provider" => "nope"}})
    assert {:error, %Wardrik.Error{message: "acme has no OAuth app nope."}} = run.(other)

    crm = server.("crm", %{"oauth" => endpoints})
    assert {:ok, %{"connected" => false}} = run.(crm)

    assert %{owner: "acme"} =
             Wardrik.OAuth.Apps.chosen(wardrik, %Principal{id: "acme"}, "server:crm")

    bad = server.("bad", %{"oauth" => Map.put(endpoints, "flow", "nope")})
    assert {:error, %Wardrik.Error{type: :invalid_request}} = run.(bad)

    assert {:ok, _removed} =
             Wardrik.run(scope, "servers.remove", %{"owner" => "acme", "name" => "crm"})

    assert nil == Wardrik.OAuth.Apps.chosen(wardrik, %Principal{id: "acme"}, "server:crm")
  end

  @tag servers: %{"notes" => "globex:notes"}
  test "refuses an agent a server another owner keeps unless it may use it", %{scope: scope} do
    {:ok, _added} = add(scope, "globex", "notes")

    assert {:error, %Wardrik.Error{type: :invalid_request, message: message}} =
             Wardrik.run(scope, "agent.define", %{
               "agent" => "acme/triage",
               "model" => "anthropic:claude-haiku-4-5"
             })

    assert message == "ana may not use globex's server notes."
  end
end
