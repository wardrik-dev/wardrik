defmodule WardrikOAuth.Tokens.Vault do
  @moduledoc """
  `WardrikOAuth.Tokens` over `WardrikVault`: each token is sealed under the
  `{:user, provider}` reference for its owner.
  """

  @behaviour WardrikOAuth.Tokens

  @impl WardrikOAuth.Tokens
  def put(provider, owner, encoded), do: WardrikVault.put({:user, provider}, owner, encoded)

  @impl WardrikOAuth.Tokens
  def fetch(provider, owner), do: WardrikVault.fetch({:user, provider}, owner)

  @impl WardrikOAuth.Tokens
  def forget(provider, owner), do: WardrikVault.forget({:user, provider}, owner)

  @impl WardrikOAuth.Tokens
  def has?(provider, owner), do: WardrikVault.has?({:user, provider}, owner)
end
