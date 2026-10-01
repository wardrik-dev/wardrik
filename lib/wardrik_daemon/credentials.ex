defmodule WardrikDaemon.Credentials do
  @moduledoc """
  Where the daemon's agents get the credentials their tools name: from
  `WardrikOAuth` where a reference names one of its providers, and from
  `WardrikVault` for every other.

  | Reference | Resolved by |
  | --- | --- |
  | `user:NAME`, `org:NAME`, where `oauth.providers` names `NAME` | `WardrikOAuth`: the user, or the org, connects an account |
  | `user:NAME`, `org:NAME`, otherwise | `WardrikVault`: the secret put for that user, or that org |
  | `named:NAME` | `WardrikVault`: the deployment's own |

  So a deployment that lets its users connect accounts can still give a
  server a secret it put in the vault itself, and a provider and a vault
  secret of the same name are the provider's.
  """

  @behaviour Wardrik.Credential

  alias Wardrik.Credential

  @impl true
  def resolve(ref, call) do
    case source(ref, providers()) do
      :oauth -> WardrikOAuth.resolve(ref, call)
      :vault -> WardrikVault.resolve(ref, call)
    end
  end

  # The vault keeps what was put in it, and has nothing to renew.
  @impl true
  def refused(ref, call) do
    case source(ref, providers()) do
      :oauth -> WardrikOAuth.refused(ref, call)
      :vault -> :ok
    end
  end

  @doc """
  Which resolves `ref` where `providers` are the names of the OAuth providers
  configured: `:oauth` for a user's or an org's credential one of them is
  named for, and `:vault` for every other.
  """
  @spec source(Credential.ref(), [String.t()]) :: :oauth | :vault
  def source({kind, name}, providers) when kind in [:user, :org],
    do: if(name in providers, do: :oauth, else: :vault)

  def source(_ref, _providers), do: :vault

  defp providers,
    do: Enum.map(WardrikOAuth.Config.providers(), fn {name, _opts} -> to_string(name) end)
end
