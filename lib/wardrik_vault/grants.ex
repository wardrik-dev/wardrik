defmodule WardrikVault.Grants do
  @moduledoc """
  The behaviour for grants: credentials a principal gives by authorizing an account, like OAuth
  tokens.

      {WardrikVault, name: MyApp.Vault, store: store, keys: keys, grants: {MyApp.OAuth, opts}}

  When a tool needs a credential, the vault calls:

    * `c:renew/2` if the principal holds it as a grant.
    * `c:ask/2` if nobody holds it, or the grant won't unseal.
    * `c:refused/2` when a service refuses the grant.

  Each callback takes a `WardrikVault.Grants.Request`, then the module's `opts`.

  Write what comes back from authorizing with `WardrikVault.put/3` and `kind: :grant`. Pass
  `:if_vsn` so two renewals never write over each other.
  """

  alias WardrikVault.Grants.Request

  @typedoc "A grant as the vault holds it. `vsn` is the version to write a renewal over."
  @type grant() :: %{value: binary(), vsn: WardrikStore.vsn()}

  @doc "Returns the credential the request's `grant` gives. Renews it first if it has run out."
  @callback renew(Request.t(), opts :: term()) ::
              {:ok, term()} | {:authorize, String.t()} | {:error, term()}

  @doc "Returns `{:authorize, url}` for the principal to authorize the grant at, or `{:error, :not_found}`."
  @callback ask(Request.t(), opts :: term()) :: {:authorize, String.t()} | {:error, term()}

  @doc "Called when a service refuses the grant the request names."
  @callback refused(Request.t(), opts :: term()) :: :ok
end
