defprotocol WardrikMCP.Auth do
  @moduledoc """
  How an owner's agents sign in to a server the owner added, as a
  `WardrikMCP.Remote` holds it: with nothing, `WardrikMCP.Auth.None`, or a
  key the owner keeps in the vault, `WardrikMCP.Auth.Secret`.

  A request names one as `{"none": {}}` or `{"secret": {"name": ...}}`,
  which `WardrikMCP.Remote.decode/2` reads.
  """

  @doc "The options of `WardrikMCP.Server.new/2` the server is reached with."
  @spec options(t()) :: keyword()
  def options(auth)

  @doc "How a listing says it signs in: `none` or `secret`."
  @spec name(t()) :: String.t()
  def name(auth)
end
