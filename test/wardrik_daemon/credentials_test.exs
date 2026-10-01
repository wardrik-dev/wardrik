defmodule WardrikDaemon.CredentialsTest do
  use ExUnit.Case, async: false

  alias Wardrik.Credential
  alias Wardrik.LLM.Config
  alias Wardrik.Scope
  alias Wardrik.Test.Calls
  alias WardrikDaemon.Credentials

  setup do
    vault = Application.get_env(:wardrik, WardrikVault)
    oauth = Application.get_env(:wardrik, WardrikOAuth)

    Application.put_env(:wardrik, WardrikVault, keys: [WardrikVault.generate_key()])

    Application.put_env(:wardrik, WardrikOAuth,
      providers: [github: [resource: "https://api.githubcopilot.com/mcp/"]]
    )

    on_exit(fn ->
      restore(WardrikVault, vault)
      restore(WardrikOAuth, oauth)
    end)

    org = "creds-#{System.unique_integer([:positive])}"
    scope = Config.new() |> Scope.root("#{org}/@jon/digest", org: org, user: "jon")
    %{org: org, call: %{Calls.tool("fetch", %{}) | scope: scope}}
  end

  defp restore(package, nil), do: Application.delete_env(:wardrik, package)
  defp restore(package, settings), do: Application.put_env(:wardrik, package, settings)

  test "a reference an OAuth provider is named for is OAuth's, and every other the vault's" do
    providers = ["github"]

    assert Credentials.source({:user, "github"}, providers) == :oauth
    assert Credentials.source({:org, "github"}, providers) == :oauth
    assert Credentials.source({:user, "pagerduty"}, providers) == :vault
    assert Credentials.source({:org, "pagerduty"}, providers) == :vault
    assert Credentials.source({:named, "github"}, providers) == :vault
    assert Credentials.source({:user, "github"}, []) == :vault
  end

  test "a secret put in the vault resolves beside an OAuth provider", %{org: org, call: call} do
    :ok = WardrikVault.put({:named, "linear"}, nil, "lin_deployment")
    :ok = WardrikVault.put({:org, "pagerduty"}, org, "pd_org")
    :ok = WardrikVault.put({:user, "sentry"}, {org, "jon"}, "sentry_jon")

    for {ref, secret} <- [
          {{:named, "linear"}, "lin_deployment"},
          {{:org, "pagerduty"}, "pd_org"},
          {{:user, "sentry"}, "sentry_jon"}
        ] do
      assert {:ok, credential} = Credentials.resolve(ref, call)
      assert Credential.reveal(credential) == secret
    end

    assert {:error, :not_found} = Credentials.resolve({:named, "missing"}, call)
    assert :ok = Credentials.refused({:named, "linear"}, call)
  end
end
