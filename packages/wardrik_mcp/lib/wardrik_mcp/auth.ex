defprotocol WardrikMCP.Auth do
  @moduledoc """
  How an owner's agents sign in to a server the owner added, as a
  `WardrikMCP.Remote` holds it: with nothing, `WardrikMCP.Auth.None`, a key
  the owner keeps in the vault, `WardrikMCP.Auth.Secret`, or a sign-in in a
  browser, `WardrikMCP.Auth.OAuth`.

  A request names one as `{"none": {}}`, `{"secret": {"name": ...}}` or
  `{"oauth": {"scopes": [...]}}`, which `WardrikMCP.Remote.decode/2` reads.
  """

  @doc """
  The options of `WardrikMCP.Server.new/2` the server `key` names is reached
  with: the credential each call resolves, where it takes one.
  """
  @spec options(t(), Wardrik.Servers.Key.t()) :: keyword()
  def options(auth, key)

  @doc "How a listing says it signs in: `none`, `secret` or `oauth`."
  @spec name(t()) :: String.t()
  def name(auth)

  @doc """
  How its owner signs in to the server `key` names at `url`: a
  `WardrikOAuth.Provider` named for the server, or `:none` where they do not
  sign in.
  """
  @spec provider(t(), Wardrik.Servers.Key.t(), String.t()) ::
          {:ok, WardrikOAuth.Provider.t()} | :none
  def provider(auth, key, url)
end
