defmodule WardrikMCP.SignInTest do
  use WardrikOAuth.Test.Case, async: false

  alias Wardrik.AgentID.Prefix
  alias Wardrik.Servers.Key
  alias WardrikMCP.Remote
  alias WardrikOAuth.Callback

  def reachable(_url), do: :ok

  setup %{owner: user} do
    start_supervised!({WardrikOAuth.Supervisor, oauth: oauth(), callback: false})
    stub_server(register: true)

    configure(
      added: %WardrikMCP.Servers.Providers{store: Wardrik.Test.store()},
      providers: [taken: [resource: resource()]]
    )

    org = "acme#{user}"
    %{org: org, owner: Prefix.new!(org: org), name: "crm"}
  end

  defp servers,
    do: %WardrikMCP.Servers{
      store: Wardrik.Test.store(),
      oauth: oauth(),
      vault: vault(),
      check: &__MODULE__.reachable/1
    }

  defp add(owner, name, auth),
    do:
      Wardrik.Servers.add(servers(), owner,
        name: name,
        fields: %{"url" => resource(), "auth" => auth},
        by: nil
      )

  test "adding one answers where its owner signs in, and the token is kept for them",
       %{org: org, owner: owner, name: name} do
    assert {:ok, %{url: url}} = add(owner, name, %{"oauth" => %{"scopes" => ["write"]}})
    assert url =~ "https://auth.example.com/authorize"
    assert params_of(url)["scope"] == "write"

    assert {:ok, ^name} = WardrikOAuth.finish(state_of(url), "the-code", provider: name)
    assert {:ok, :grant, _token} = WardrikVault.lookup(vault(), name, org)

    {:ok, remote} = Remote.fetch(Wardrik.Test.store(), Key.new(owner, name))
    assert Remote.server(remote, store: Wardrik.Test.store()).credential == name

    assert :ok = Wardrik.Servers.remove(servers(), owner, name: name, by: nil)
    assert {:error, :not_found} = WardrikVault.lookup(vault(), name, org)
  end

  test "is a provider of its owner's alone, reached as a server named it",
       %{org: org, owner: owner, name: name} do
    {:ok, _link} = add(owner, name, %{"oauth" => %{}})

    assert {:ok, provider} = WardrikOAuth.Provider.fetch(oauth(), name, org)
    assert provider.trust == :discovered
    assert :error = WardrikOAuth.Provider.fetch(oauth(), name, "globex")
    assert :error = WardrikOAuth.Provider.fetch(oauth(), name, {org, "jon"})
    assert name in WardrikOAuth.Provider.names(oauth())
    assert Callback.redirect_uri(oauth(), name) in WardrikOAuth.document(oauth())["redirect_uris"]
  end

  test "one reached with nothing, or a secret, is no provider", %{org: org, owner: owner} do
    assert {:ok, :connected} = add(owner, "docs", %{"none" => %{}})
    assert {:ok, :connected} = add(owner, "keyed", %{"secret" => %{"name" => "k"}})

    assert :error = WardrikOAuth.Provider.fetch(oauth(), "docs", org)
    assert :error = WardrikOAuth.Provider.fetch(oauth(), "keyed", org)
  end

  test "a name the deployment offers as an account is refused", %{owner: owner} do
    assert {:error, %Wardrik.Error{type: :conflict}} = add(owner, "taken", %{"oauth" => %{}})
  end

  test "a sign-in that cannot start leaves nothing added", %{owner: owner, name: name} do
    stub_server(no_pkce: true)

    assert {:error, %Wardrik.Error{type: :unavailable}} = add(owner, name, %{"oauth" => %{}})
    assert Wardrik.Servers.list(servers(), owner) == []
  end
end
