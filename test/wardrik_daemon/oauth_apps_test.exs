defmodule WardrikDaemon.OAuthAppsTest do
  use ExUnit.Case, async: false
  use Mimic

  import WardrikDaemon.Test

  alias WardrikCore.Credentials
  alias WardrikCore.Principal
  alias WardrikDaemon.Client
  alias WardrikDaemon.OAuthApps
  alias WardrikDaemon.Tokens
  alias WardrikOAuth.Resolver.Request
  alias WardrikOAuth.Token
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
    oauth:
      providers:
        crm:
          authorization_endpoint: https://crm.test/authorize
          token_endpoint: https://crm.test/token
          client_id: deployment-crm
          client_secret: deployment-secret
    bindings:
      - {org: payments, role: operator, subjects: [user:ana]}
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

  defp app(name, client_id, extra \\ %{}) do
    Map.merge(
      %{
        "name" => name,
        "authorization_endpoint" => "https://#{client_id}.test/authorize",
        "token_endpoint" => "https://#{client_id}.test/token",
        "client_id" => client_id
      },
      extra
    )
  end

  defp add(client, owner, input),
    do: Client.run(client, "providers.add", Map.put(input, "owner", owner))

  defp list(client, owner), do: Client.run(client, "providers.list", %{"owner" => owner})

  defp remove(client, owner, name),
    do: Client.run(client, "providers.remove", %{"owner" => owner, "name" => name})

  defp resolve(context, id, name),
    do: OAuthApps.provider(%Request{name: name, principal: %Principal{id: id}}, context.daemon)

  defp client_id(url), do: URI.decode_query(URI.parse(url).query)["client_id"]

  defp seal(context, {owner, name}, value, kind) do
    secret = %Secret{principal: %Principal{id: owner}, name: name, value: value}
    {:ok, _vsn} = WardrikVault.put(Wardrik.vault(context.running), secret, kind: kind)
  end

  # A grant the app `key` issued, expired, which only that app may refresh.
  defp grant(context, {id, name}, key) do
    token = %Token{
      access_token: "old",
      refresh_token: "rt",
      expires_at: 0,
      token_endpoint: "http://127.0.0.1:1/token",
      provider: key
    }

    seal(context, {id, name}, Token.encode(token), :grant)
  end

  defp credential(context, id, name) do
    request = %Credentials.Request{name: name, principal: %Principal{id: id}}
    WardrikVault.resolve(request, Wardrik.vault(context.running))
  end

  test "signs a principal in only with an app its chain reaches", context do
    admin = client(context, "user:admin")
    assert {:ok, _app} = add(admin, "payments", app("crm", "payments-crm"))
    assert {:ok, _app} = add(admin, "growth", app("crm", "growth-crm"))
    assert {:ok, _app} = add(admin, "growth/@cy", app("notes", "cy-notes"))

    assert {:ok, %{client_id: "payments-crm"}} = resolve(context, "payments/@ana", "crm")
    assert {:ok, %{client_id: "payments-crm"}} = resolve(context, "payments", "crm")
    assert {:ok, %{client_id: "growth-crm"}} = resolve(context, "growth/@cy", "crm")
    assert {:ok, %{client_id: "deployment-crm"}} = resolve(context, "initech/@bo", "crm")

    assert {:ok, %{client_id: "cy-notes"}} = resolve(context, "growth/@cy", "notes")

    for id <- ["growth", "growth/@di", "payments/@ana", "deployment"],
        do: assert(resolve(context, id, "notes") == {:error, :not_found})

    ana = client(context, "user:payments/@ana")

    assert {:ok, %{"authorization" => %{"url" => url}}} =
             Client.run(ana, "connections.connect", %{"provider" => "crm"})

    assert client_id(url) == "payments-crm"

    assert {:ok, %{"providers" => listed}} = list(admin, "growth/@cy")

    assert for(app <- listed, do: {app["owner"], app["name"], app["source"]}) == [
             {"growth/@cy", "notes", "runtime"},
             {"growth", "crm", "runtime"}
           ]

    assert {:ok, %{"providers" => [deployment]}} = list(admin, "deployment")

    assert deployment == %{
             "owner" => "deployment",
             "name" => "crm",
             "source" => "config",
             "authorization_endpoint" => "https://crm.test/authorize",
             "token_endpoint" => "https://crm.test/token",
             "client_id" => "deployment-crm",
             "client_auth" => "post",
             "flow" => "browser",
             "scopes" => []
           }
  end

  test "refreshes a grant only by the app that issued it", context do
    admin = client(context, "user:admin")
    assert {:ok, _app} = add(admin, "payments", app("crm", "payments-crm"))
    issuer = OAuthApps.key(OAuthApps.nearest(context.daemon, "payments", "crm"))

    # The issuer refreshes it, though its token endpoint is down.
    grant(context, {"payments/@ana", "crm"}, issuer)
    assert {:error, _down} = credential(context, "payments/@ana", "crm")

    # Ana's own app of the name is another app: she signs in again with it.
    assert {:ok, _app} = add(admin, "payments/@ana", app("crm", "ana-crm"))
    grant(context, {"payments/@ana", "crm"}, issuer)
    assert {:authorize, url} = credential(context, "payments/@ana", "crm")
    assert client_id(url) == "ana-crm"

    # So is an app removed and added again by the same name.
    assert {:ok, _app} = remove(admin, "payments/@ana", "crm")
    assert {:ok, _app} = remove(admin, "payments", "crm")
    assert {:ok, _app} = add(admin, "payments", app("crm", "payments-crm"))
    refute OAuthApps.key(OAuthApps.nearest(context.daemon, "payments", "crm")) == issuer

    grant(context, {"payments/@bo", "crm"}, issuer)
    assert {:authorize, _url} = credential(context, "payments/@bo", "crm")

    # And the deployment's, for a grant another org's app issued.
    grant(context, {"initech/@di", "crm"}, issuer)
    assert {:authorize, url} = credential(context, "initech/@di", "crm")
    assert client_id(url) == "deployment-crm"
  end

  test "a token bound in one org can't add, list or remove another org's apps", context do
    admin = client(context, "user:admin")
    ana = client(context, "user:ana")
    assert {:ok, _app} = add(admin, "growth", app("crm", "growth-crm"))

    assert {:ok, %{"name" => "docs"}} = add(ana, "payments", app("docs", "payments-docs"))
    assert {:ok, %{"providers" => [%{"name" => "docs"} | _rest]}} = list(ana, "payments")

    for owner <- ["growth", "growth/@cy", "deployment"] do
      assert {:error, "not_found", _message} = list(ana, owner)
      assert {:error, "not_found", _message} = add(ana, owner, app("mine", "mine"))
      assert {:error, "not_found", _message} = remove(ana, owner, "crm")
    end

    assert OAuthApps.nearest(context.daemon, "growth", "mine") == nil
    assert %{owner: "growth"} = OAuthApps.nearest(context.daemon, "growth", "crm")

    cy = client(context, "user:growth/@cy")
    assert {:ok, _app} = add(cy, "growth/@cy", app("notes", "cy-notes"))
    assert {:error, "not_found", _message} = remove(cy, "growth", "crm")
    assert {:error, "not_found", _message} = add(cy, "growth/@di", app("notes", "di-notes"))
    assert {:ok, %{"name" => "notes"}} = remove(cy, "growth/@cy", "notes")

    assert {:error, "conflict", _message} = add(admin, "growth", app("crm", "again"))
    assert {:error, "conflict", _message} = add(admin, "deployment", app("crm", "again"))
    assert {:error, "invalid_request", _message} = remove(admin, "deployment", "crm")
    assert {:error, "not_found", _message} = remove(admin, "growth", "nope")

    assert {:ok, %{"events" => events}} = Wardrik.run(context.admin, "audit.list", %{})

    assert for(%{"subject" => "providers/notes"} = event <- events, do: event["type"]) ==
             ["wardrik.provider.added", "wardrik.provider.removed"]
  end

  test "references a client secret, never storing or answering it", context do
    admin = client(context, "user:admin")
    input = app("crm", "growth-crm", %{"client_secret" => %{"name" => "CRM_SECRET"}})

    assert {:error, "invalid_request",
            "growth holds no secret CRM_SECRET sealed as a client_secret."} =
             add(admin, "growth", input)

    seal(context, {"growth", "CRM_SECRET"}, "sk-first", :header)
    assert {:error, "invalid_request", _message} = add(admin, "growth", input)

    seal(context, {"growth", "CRM_SECRET"}, "sk-first", :client_secret)
    assert {:ok, added} = add(admin, "growth", input)
    assert added["client_secret"] == %{"name" => "CRM_SECRET"}

    assert {:ok, %{client_secret: "sk-first"}} = resolve(context, "growth/@cy", "crm")
    seal(context, {"growth", "CRM_SECRET"}, "sk-rotated", :client_secret)
    assert {:ok, %{client_secret: "sk-rotated"}} = resolve(context, "growth/@cy", "crm")

    assert {:ok, listed} = list(admin, "growth")
    refute JSON.encode!(listed) =~ "sk-"
    refute JSON.encode!(listed) =~ "deployment-secret"
    refute :erlang.term_to_binary(WardrikStore.entries(context.daemon_store, "")) =~ "sk-"

    :ok =
      WardrikVault.delete(Wardrik.vault(context.running), %Principal{id: "growth"}, "CRM_SECRET")

    assert {:error, "crm's client secret CRM_SECRET isn't sealed for growth"} =
             resolve(context, "growth/@cy", "crm")
  end

  test "refuses an app whose URLs the egress check refuses, or that doesn't read", context do
    stub(Wardrik.Egress, :any, fn
      "https://169.254.169.254" <> _rest -> {:error, "169.254.169.254 is a private address"}
      _url -> :ok
    end)

    admin = client(context, "user:admin")
    inside = app("wiki", "inside", %{"token_endpoint" => "https://169.254.169.254/token"})

    assert {:error, "invalid_request", message} = add(admin, "growth", inside)
    assert message == "The token_endpoint can't be reached: 169.254.169.254 is a private address."

    for input <- [
          %{"name" => "wiki"},
          %{app("wiki", "x") | "name" => "a:b"},
          Map.put(app("wiki", "x"), "client_secret", "inline"),
          Map.put(app("wiki", "x"), "authorization_params", %{"state" => "mine"})
        ] do
      assert {:error, "invalid_request", _message} = add(admin, "growth", input)
    end

    assert OAuthApps.nearest(context.daemon, "growth", "wiki") == nil
  end

  test "connections list and forget only the caller's own grants", context do
    admin = client(context, "user:admin")
    assert {:ok, _app} = add(admin, "payments", app("docs", "payments-docs"))

    seal(context, {"payments/@ana", "crm"}, "ana's grant", :grant)
    seal(context, {"payments/@bo", "docs"}, "bo's grant", :grant)

    ana = client(context, "user:payments/@ana")
    bo = client(context, "user:payments/@bo")

    assert {:ok, %{"connections" => connections}} = Client.run(ana, "connections.list", %{})

    assert Enum.sort_by(connections, & &1["provider"]) == [
             %{"provider" => "crm", "connected" => true, "signing_in" => false},
             %{"provider" => "docs", "connected" => false, "signing_in" => false}
           ]

    assert {:ok, %{"provider" => "crm", "connected" => true}} =
             Client.run(ana, "connections.connect", %{"provider" => "crm"})

    assert {:ok, %{"provider" => "crm", "connected" => false}} =
             Client.run(bo, "connections.disconnect", %{"provider" => "crm"})

    assert {:ok, %{"provider" => "docs", "connected" => true}} =
             Client.run(bo, "connections.disconnect", %{"provider" => "docs"})

    vault = Wardrik.vault(context.running)

    assert {:ok, "ana's grant"} =
             WardrikVault.fetch(vault, %Principal{id: "payments/@ana"}, "crm")

    assert {:error, :not_found} =
             WardrikVault.fetch(vault, %Principal{id: "payments/@bo"}, "docs")

    assert {:error, "not_found", _message} =
             Client.run(ana, "connections.connect", %{"provider" => "nope"})

    # An agent's token acts for its owner, but manages no connections without a binding.
    agent = client(context, "agent:" <> recorded(context, "payments/@ana/notes"))
    assert {:error, "not_found", _message} = Client.run(agent, "connections.list", %{})

    assert {:error, "not_found", _message} =
             Client.run(agent, "connections.disconnect", %{"provider" => "crm"})

    assert {:ok, "ana's grant"} =
             WardrikVault.fetch(vault, %Principal{id: "payments/@ana"}, "crm")
  end
end
