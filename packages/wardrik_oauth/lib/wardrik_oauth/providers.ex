defprotocol WardrikOAuth.Providers do
  @moduledoc """
  Providers beyond those a deployment configures, each for an owner: such as
  the MCP servers an org or a person adds, each signed in to as itself. A
  `WardrikOAuth`'s `:added` holds one, and a name its `:providers` does not
  configure is looked up there, for the owner a sign-in is for.

  A provider found here is reached as one a server named, never as one the
  deployment did: its `:trust` is `:discovered`, so every request it makes
  goes to public addresses alone; see `WardrikOAuth.Egress`.

  `%WardrikOAuth.Providers.None{}` adds none.
  """

  @doc "The provider `name` is for `:owner`, where one is added for them."
  @spec fetch(t(), String.t(), owner: WardrikVault.owner()) ::
          {:ok, WardrikOAuth.Provider.t()} | :error
  def fetch(providers, name, opts)

  @doc """
  Every name a provider is added under, for any owner: where a sign-in may
  come back to, as the client's document lists its redirect URIs.
  """
  @spec names(t()) :: [String.t()]
  def names(providers)
end
