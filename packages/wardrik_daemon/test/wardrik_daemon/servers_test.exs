defmodule WardrikDaemon.ServersTest do
  use ExUnit.Case, async: false
  use Mimic

  import WardrikDaemon.Test

  alias Wardrik.Resolver.Request
  alias WardrikCore.Principal
  alias WardrikDaemon.Client
  alias WardrikDaemon.OAuthApps
  alias WardrikDaemon.Servers
  alias WardrikDaemon.Tokens
  alias WardrikVault.Secret

  setup :set_mimic_global

  setup context do
    context = dirs(context)
    port = free_port()

    write(context, "config.yaml", """
    org: payments
    orgs: {growth: {}}
    allow_private_urls: true
    http: {port: #{port}}
    defaults: {model: #{model()}}
    oauth: {client_name: Agents}
    mcp:
      search: {url: "http://127.0.0.1:1/search"}
    roles:
      adder: {rules: [{verbs: [add, read], kinds: [mcp_server]}]}
      remover: {rules: [{verbs: [delete, read], kinds: [mcp_server]}]}
    bindings:
      - {org: payments, role: operator, subjects: [user:payments/@ana]}
      - {org: payments, role: adder, subjects: [user:payments/@bo]}
      - {org: payments, role: remover, subjects: [user:payments/@dee]}
    """)

    context = start_daemon(context)
    running = Wardrik.Instance.fetch!(context.wardrik)
    {WardrikDaemon.Resolver, daemon} = running.resolver
    Map.merge(context, %{url: "http://127.0.0.1:#{port}", running: running, daemon: daemon})
  end

  defp client(context, subject) do
    {:ok, %{secret: secret}} =
      Tokens.create(context.daemon_store,
        name: "test",
        subject: subject,
        expires: DateTime.add(DateTime.utc_now(), 1, :hour)
      )

    %Client{url: context.url, secret: secret}
  end

  defp server(name, auth \\ %{"none" => %{}}),
    do: %{"name" => name, "url" => "http://127.0.0.1:1/#{name}", "auth" => auth}

  defp add(client, owner, input),
    do: Client.run(client, "servers.add", Map.put(input, "owner", owner))

  defp list(client, owner), do: Client.run(client, "servers.list", %{"owner" => owner})

  defp remove(client, owner, name),
    do: Client.run(client, "servers.remove", %{"owner" => owner, "name" => name})

  defp servers(context, id) do
    request = %Request{agent: recorded(context, id)}
    {:ok, resolved} = Wardrik.Resolver.resolve(context.running, request)
    resolved.servers
  end

  defp mcp(context), do: Wardrik.mcp(context.running)

  defp seal(context, owner, name, kind) do
    secret = %Secret{principal: %Principal{id: owner}, name: name, value: "sk-" <> name}
    {:ok, _vsn} = WardrikVault.put(Wardrik.vault(context.running), secret, kind: kind)
  end

  test "an owner's server reaches only the agents the resolver gives it to", context do
    admin = client(context, "user:admin")

    for owner <- ["payments", "payments/@ana", "growth"],
        do: assert({:ok, %{"connected" => true}} = add(admin, owner, server("crm")))

    assert {:ok, _added} = add(admin, "deployment", server("wiki"))

    assert servers(context, "payments/@ana/notes")["crm"] == "payments/@ana:crm"
    assert servers(context, "payments/@bo/notes")["crm"] == "payments:crm"
    assert servers(context, "payments/triage")["crm"] == "payments:crm"
    assert servers(context, "growth/@cy/leads")["crm"] == "growth:crm"
    assert servers(context, "growth/leads")["wiki"] == "deployment:wiki"

    for id <- ["payments/triage", "payments/@ana/notes"],
        do: refute("growth:crm" in Map.values(servers(context, id)))

    assert "search" in Map.keys(servers(context, "payments/triage"))
    refute "search" in Map.keys(servers(context, "growth/leads"))

    assert {:ok, %{"servers" => listed}} = list(admin, "payments/@ana")

    assert for(server <- listed, do: {server["owner"], server["name"], server["source"]}) == [
             {"payments/@ana", "crm", "runtime"},
             {"deployment", "wiki", "runtime"},
             {"deployment", "search", "config"}
           ]
  end

  test "a token bound in one org can't add, list or remove another org's servers", context do
    admin = client(context, "user:admin")
    ana = client(context, "user:payments/@ana")
    {:ok, _added} = add(admin, "growth", server("crm"))

    assert {:ok, %{"connected" => true}} = add(ana, "payments", server("docs"))
    assert {:ok, %{"servers" => [%{"name" => "docs"} | _rest]}} = list(ana, "payments")

    for owner <- ["growth", "growth/@cy", "deployment"] do
      assert {:error, "not_found", _message} = list(ana, owner)
      assert {:error, "not_found", _message} = add(ana, owner, server("mine"))
      assert {:error, "not_found", _message} = remove(ana, owner, "crm")
    end

    assert "growth:crm" in WardrikMCP.servers(mcp(context))
    refute "growth:mine" in WardrikMCP.servers(mcp(context))

    cy = client(context, "user:growth/@cy")
    assert {:ok, _added} = add(cy, "growth/@cy", server("notes"))
    assert {:error, "not_found", _message} = remove(cy, "growth", "crm")
    assert {:ok, %{"name" => "notes"}} = remove(cy, "growth/@cy", "notes")
  end

  test "reaches a server with a secret named, never kept or answered", context do
    admin = client(context, "user:admin")
    input = server("crm", %{"secret" => %{"name" => "CRM_KEY", "scheme" => "Token"}})

    assert {:error, "invalid_request", message} = add(admin, "growth", input)
    assert message == "growth holds no secret CRM_KEY sealed as a header."

    seal(context, "growth", "CRM_KEY", :api_key)
    assert {:error, "invalid_request", _message} = add(admin, "growth", input)

    seal(context, "growth", "CRM_KEY", :header)
    assert {:ok, %{"connected" => true}} = add(admin, "growth", input)

    assert %WardrikMCP.Server{transport: {:streamable_http, http}, owner: "growth"} =
             WardrikMCP.Servers.all(mcp(context))["growth:crm"]

    assert http[:headers] == %{"authorization" => ["Token ", {:secret, "CRM_KEY"}]}

    assert {:ok, %{"servers" => listed} = answer} = list(admin, "growth")
    assert %{"name" => "crm", "auth" => "secret"} = hd(listed)
    refute JSON.encode!(answer) =~ "sk-"

    stored = :erlang.term_to_binary(WardrikStore.entries(context.daemon_store, "servers/"))
    refute stored =~ "sk-CRM_KEY"
    refute :erlang.term_to_binary(WardrikStore.entries(context.running.store, "")) =~ "sk-CRM_KEY"
  end

  test "refuses a URL the egress check refuses, and a server it doesn't read", context do
    stub(Wardrik.Egress, :any, fn
      "https://169.254.169.254" <> _rest -> {:error, "169.254.169.254 is a private address"}
      _url -> :ok
    end)

    admin = client(context, "user:admin")
    inside = %{server("inside") | "url" => "https://169.254.169.254/mcp"}

    assert {:error, "invalid_request", message} = add(admin, "growth", inside)
    assert message == "The server can't be reached: 169.254.169.254 is a private address."
    refute "growth:inside" in WardrikMCP.servers(mcp(context))

    for input <- [
          Map.delete(server("x"), "auth"),
          %{server("x") | "name" => "a__b:c"},
          Map.put(server("x"), "headers", %{"authorization" => "Bearer x"}),
          server("x", %{"oauth" => %{"provider" => "google", "client_id" => "app"}})
        ] do
      assert {:error, "invalid_request", _message} = add(admin, "growth", input)
    end

    {:ok, _added} = add(admin, "growth", server("crm"))
    assert {:error, "conflict", _message} = add(admin, "growth", server("crm"))
    assert {:error, "not_found", _message} = remove(admin, "growth", "nope")
    assert {:error, "invalid_request", _message} = remove(admin, "deployment", "search")
  end

  test "signs in with the server's own app, made for it, and forgets it as it's removed",
       context do
    admin = client(context, "user:admin")

    oauth = %{
      "authorization_endpoint" => "https://crm-auth.test/authorize",
      "token_endpoint" => "https://crm-auth.test/token",
      "client_id" => "growth-app",
      "scopes" => ["read"]
    }

    assert {:ok, %{"server" => "crm", "connected" => false, "authorization" => %{"url" => url}}} =
             add(admin, "growth", server("crm", %{"oauth" => oauth}))

    assert "https://crm-auth.test/authorize?" <> query = url
    assert %{"client_id" => "growth-app", "scope" => "read"} = URI.decode_query(query)

    assert %{owner: "growth"} = OAuthApps.nearest(context.daemon, "growth/@cy", "growth:crm")

    assert {:ok, %{"providers" => []}} =
             Client.run(admin, "providers.list", %{"owner" => "growth"})

    cy = client(context, "user:growth/@cy")

    assert {:ok, %{"connections" => [%{"provider" => "crm", "connected" => false}]}} =
             Client.run(cy, "connections.list", %{})

    assert {:ok, %{"auth" => "oauth"}} = remove(admin, "growth", "crm")
    assert OAuthApps.nearest(context.daemon, "growth/@cy", "growth:crm") == nil
    assert {:ok, %{"connections" => []}} = Client.run(cy, "connections.list", %{})
  end

  test "signs in with an OAuth app the owner can use, leaving it as the server is removed",
       context do
    admin = client(context, "user:admin")

    {:ok, _app} =
      Client.run(admin, "providers.add", %{
        "owner" => "growth",
        "name" => "google",
        "authorization_endpoint" => "https://google.test/authorize",
        "token_endpoint" => "https://google.test/token",
        "client_id" => "google-app"
      })

    ads = server("ads", %{"oauth" => %{"provider" => "google"}})

    assert {:ok,
            %{"connected" => false, "authorization" => %{"url" => "https://google.test" <> _}}} =
             add(admin, "growth/@cy", ads)

    assert %WardrikMCP.Server{credential_name: "google"} =
             WardrikMCP.Servers.all(mcp(context))["growth/@cy:ads"]

    assert {:error, "invalid_request", "payments has no OAuth app google."} =
             add(admin, "payments", ads)

    assert {:ok, %{"name" => "ads"}} = remove(admin, "growth/@cy", "ads")

    assert {:ok, %{"providers" => [_google]}} =
             Client.run(admin, "providers.list", %{"owner" => "growth"})
  end

  test "stops a server removed on every node, and starts every kept one as the daemon starts",
       context do
    admin = client(context, "user:admin")
    {:ok, _added} = add(admin, "growth", server("crm"))
    {:ok, _added} = add(admin, "payments", server("docs"))

    # Another node: its own WardrikMCP over the same store.
    other = :"other #{context.test}"

    start_supervised!(
      {WardrikMCP, name: other, store: context.running.store, reconcile: :infinity}
    )

    :ok = WardrikMCP.reconcile(other)
    assert WardrikMCP.servers(other) == ["growth:crm", "payments:docs"]

    assert {:ok, %{"name" => "crm"}} = remove(admin, "growth", "crm")
    refute "growth:crm" in WardrikMCP.servers(mcp(context))
    :ok = WardrikMCP.reconcile(other)
    assert WardrikMCP.servers(other) == ["payments:docs"]

    assert {:ok, %{"events" => events}} = Wardrik.run(context.admin, "audit.list", %{})

    assert for(%{"subject" => "servers/crm"} = event <- events, do: event["type"]) ==
             ["wardrik.server.added", "wardrik.server.removed"]

    # The daemon's own record is what starts: one WardrikMCP lost is started again, and one it
    # kept that the daemon doesn't is stopped.
    :ok = WardrikMCP.remove(mcp(context), "payments:docs")

    :ok =
      WardrikMCP.add(mcp(context), "growth:stray",
        transport: {:streamable_http, url: "http://127.0.0.1:1/stray"}
      )

    ref = :telemetry_test.attach_event_handlers(self(), [[:wardrik_daemon, :started]])

    ExUnit.CaptureLog.capture_log(fn ->
      :ok = Supervisor.terminate_child(WardrikDaemon.Server, WardrikDaemon.Running)
      {:ok, _pid} = Supervisor.restart_child(WardrikDaemon.Server, WardrikDaemon.Running)
      assert_receive {[:wardrik_daemon, :started], ^ref, _measurements, _meta}, 5_000
    end)

    running = Wardrik.Instance.fetch!(context.wardrik)
    assert "payments:docs" in WardrikMCP.servers(Wardrik.mcp(running))
    refute "growth:stray" in WardrikMCP.servers(Wardrik.mcp(running))
    refute "growth:crm" in WardrikMCP.servers(Wardrik.mcp(running))
  end

  test "starts what the store keeps and stops what it doesn't, each time it's asked", context do
    admin = client(context, "user:admin")
    {:ok, _added} = add(admin, "growth", server("crm"))
    :ok = WardrikMCP.remove(mcp(context), "growth:crm")

    assert :ok = Servers.start(context.wardrik, context.daemon_store)
    assert "growth:crm" in WardrikMCP.servers(mcp(context))
    assert "search" in WardrikMCP.servers(mcp(context))
  end

  # Removing is its own verb, as Kubernetes' delete: adding doesn't allow it.
  test "removing a server needs delete, not add", context do
    adder = client(context, "user:payments/@bo")
    remover = client(context, "user:payments/@dee")

    assert {:ok, _added} = add(adder, "payments", server("crm"))
    assert {:error, "forbidden", _message} = remove(adder, "payments", "crm")
    assert {:error, "forbidden", _message} = add(remover, "payments", server("docs"))
    assert {:ok, _removed} = remove(remover, "payments", "crm")
    assert {:ok, %{"servers" => servers}} = list(adder, "payments")
    refute "crm" in Enum.map(servers, & &1["name"])
  end
end
