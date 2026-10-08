defmodule WardrikVault.Grants do
  @moduledoc """
  What `WardrikVault` hands a grant to: a module that renews the grants it
  gave, and asks for one where nobody holds a name it can grant.
  `WardrikOAuth` is one, and `WardrikVault`'s `:grants` option names it.

  A grant is kept in the vault like any other credential, sealed under its
  name and owner with `WardrikVault.put/4` and `kind: :grant`. What it holds is
  the module's own: the vault never reads inside it.
  """

  @doc "Whether the module can grant `name`, so a name nobody holds is asked for."
  @callback grants?(name :: String.t()) :: boolean()

  @doc """
  The credential the grant `value`, held as `name` for `owner`, answers
  with, renewing it where it has run out, and writing back what it renewed.
  """
  @callback renew(name :: String.t(), owner :: WardrikVault.owner(), value :: String.t()) ::
              Wardrik.Credential.outcome()

  @doc """
  Asks `owner` to authorize `name`: what a call parks on until they have,
  `{:error, {:authorization_required, link, owner}}`. Once they have, the
  module keeps the grant with `WardrikVault.put/4` and says so with
  `Wardrik.Credential.available/3`, and the call carries on.
  """
  @callback ask(name :: String.t(), owner :: WardrikVault.owner()) ::
              Wardrik.Credential.outcome()

  @doc "Hears that the grant held as `name` for `owner` was refused by the server it was for."
  @callback refused(name :: String.t(), owner :: WardrikVault.owner()) :: :ok
end
