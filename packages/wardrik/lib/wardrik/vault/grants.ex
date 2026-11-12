defmodule Wardrik.Vault.Grants do
  @moduledoc """
  Refreshes and asks for credentials a user gives by signing in, like OAuth tokens.
  `Wardrik.OAuth` implements it.

      {Wardrik.Vault, name: MyApp.Vault, store: store, keys: keys, grants: {MyApp.OAuth, opts}}

  When a tool needs a credential, the vault calls:

    * `c:renew/2` if the principal holds it as a grant.
    * `c:ask/2` if nobody holds it, or the grant won't unseal.
    * `c:refused/2` when a service refuses the grant.

  Write new tokens with `Wardrik.Vault.put/3`, `kind: :grant` and `:if_vsn`, so two renewals never
  write over each other.
  """

  alias Wardrik.Vault.Grants.Request

  @typedoc "A grant as the vault holds it. `vsn` is the version to write a renewal over."
  @type grant() :: %{value: binary(), vsn: Wardrik.Store.vsn()}

  @doc "Returns the credential the request's `grant` gives. Renews it first if it has run out."
  @callback renew(Request.t(), opts :: term()) ::
              {:ok, term()} | {:authorize, String.t()} | {:error, term()}

  @doc "Returns `{:authorize, url}` where the user signs in, or `{:error, :not_found}`."
  @callback ask(Request.t(), opts :: term()) :: {:authorize, String.t()} | {:error, term()}

  @doc "Called when a service refuses the grant the request names."
  @callback refused(Request.t(), opts :: term()) :: :ok
end
