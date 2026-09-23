defmodule TarsOAuth.Tokens.Vault do
  @moduledoc """
  `TarsOAuth.Tokens` over `TarsVault`: each token is sealed under the
  `{:user, provider}` reference for its owner.
  """

  @behaviour TarsOAuth.Tokens

  @impl TarsOAuth.Tokens
  def put(provider, owner, encoded), do: TarsVault.put({:user, provider}, owner, encoded)

  @impl TarsOAuth.Tokens
  def fetch(provider, owner), do: TarsVault.fetch({:user, provider}, owner)

  @impl TarsOAuth.Tokens
  def forget(provider, owner), do: TarsVault.forget({:user, provider}, owner)

  @impl TarsOAuth.Tokens
  def has?(provider, owner), do: TarsVault.has?({:user, provider}, owner)
end
