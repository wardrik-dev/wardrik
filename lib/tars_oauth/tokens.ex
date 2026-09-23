defmodule TarsOAuth.Tokens do
  @moduledoc """
  Where a user's tokens are kept between the flow that got them and the calls
  that use them.

  `TarsOAuth` writes a token here once a user has authorized, reads it back on
  every resolve, and forgets it on disconnect. `TarsOAuth.Tokens.Vault` is the
  default and seals tokens with `TarsVault`. A deployment with a token table of
  its own implements this behaviour and names it:

      config :tars, TarsOAuth, tokens: MyApp.OAuthTokens

  A token travels as the string `TarsOAuth.Token.encode/1` produces.
  """

  @typedoc "The provider a token is for, by name."
  @type provider() :: String.t()

  @typedoc "Who the token belongs to, as the host's own value."
  @type owner() :: term()

  @doc "Writes a token, replacing whatever was there."
  @callback put(provider(), owner(), encoded :: String.t()) :: :ok | {:error, term()}

  @doc "Reads a token, or `{:error, :not_found}`."
  @callback fetch(provider(), owner()) :: {:ok, String.t()} | {:error, :not_found | term()}

  @doc "Removes a token. Removing one that is not there is `:ok`."
  @callback forget(provider(), owner()) :: :ok | {:error, term()}

  @doc "Whether a token is held."
  @callback has?(provider(), owner()) :: boolean()
end
