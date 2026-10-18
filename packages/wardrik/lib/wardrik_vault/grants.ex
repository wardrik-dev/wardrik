defprotocol WardrikVault.Grants do
  @moduledoc """
  What `WardrikVault` hands a grant to: a value that renews the grants it
  gave, and asks for one where nobody holds a name it can grant.
  `WardrikOAuth`'s is one, and a vault's `:grants` holds it.

  A grant is kept in the vault like any other credential, sealed under its
  name and owner with `WardrikVault.put/4` and `kind: :grant`. What it holds
  is the grants' own: the vault never reads inside it. Each function but
  `grants?/3` is handed the vault it is kept in, as `:vault`.

  A vault that grants nothing has `%WardrikVault.Grants.None{}`.
  """

  @doc """
  Whether these grants can grant `name` to `owner`, so a name nobody holds
  is asked for.
  """
  @spec grants?(t(), String.t(), WardrikVault.owner()) :: boolean()
  def grants?(grants, name, owner)

  @doc """
  The credential the grant `:value` `opts` name, held as `name` for `owner`,
  answers with, renewing it where it has run out, and writing back what it
  renewed into `:vault`.
  """
  @spec renew(t(), String.t(), WardrikVault.owner(), vault: WardrikVault.t(), value: String.t()) ::
          Wardrik.Credential.outcome()
  def renew(grants, name, owner, opts)

  @doc """
  Asks `owner` to authorize `name`: what a call parks on until they have,
  `{:error, {:authorization_required, link, owner}}`. Once they have, the
  grant is kept in `:vault` with `WardrikVault.put/4`, and said with
  `Wardrik.Credential.available/3`, and the call carries on.
  """
  @spec ask(t(), String.t(), WardrikVault.owner(), vault: WardrikVault.t()) ::
          Wardrik.Credential.outcome()
  def ask(grants, name, owner, opts)

  @doc "Hears that the grant held as `name` for `owner` was refused by the server it was for."
  @spec refused(t(), String.t(), WardrikVault.owner(), vault: WardrikVault.t()) :: :ok
  def refused(grants, name, owner, opts)
end

defmodule WardrikVault.Grants.None do
  @moduledoc """
  The `WardrikVault.Grants` of a vault that grants nothing: no name is asked
  for, and a grant found, kept before, answers `:not_found`.
  """

  defstruct []

  @type t() :: %__MODULE__{}
end

defimpl WardrikVault.Grants, for: WardrikVault.Grants.None do
  def grants?(_grants, _name, _owner), do: false
  def renew(_grants, _name, _owner, _opts), do: {:error, :not_found}
  def ask(_grants, _name, _owner, _opts), do: {:error, :not_found}
  def refused(_grants, _name, _owner, _opts), do: :ok
end
