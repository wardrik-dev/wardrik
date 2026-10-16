defprotocol Wardrik.Credentials do
  @moduledoc """
  Where the secrets tools and model providers need come from: the host's
  answer to a `Wardrik.Credential` a tool names, and to a provider's key.

  A host names the value once, as the `:credentials` of its `Wardrik.Host`,
  and every call resolves through it, whichever agent makes it. The value
  carries what its implementation needs, such as the keys a vault unseals
  with, so nothing secret is stored with an agent:

      Wardrik.Host.new(credentials: WardrikVault.new(store: store, keys: keys))

  A host that names none has `Wardrik.Credentials.None`, which resolves
  nothing, so the default costs nothing.
  """

  @doc """
  Resolves one reference for the principal the call's scope names.

  Called in the process making the call, as often as the call is made. An
  implementation that caches is free to; core asks every time.
  """
  @spec resolve(t(), Wardrik.Credential.ref(), Wardrik.Call.t()) :: Wardrik.Credential.outcome()
  def resolve(credentials, ref, call)

  @doc """
  Hears that the credential last resolved for `ref` was refused by the server
  it was for, so the next resolve renews it or asks again; `:ok` where there
  is nothing to renew.
  """
  @spec refused(t(), Wardrik.Credential.ref(), Wardrik.Call.t()) :: :ok
  def refused(credentials, ref, call)

  @doc """
  The deployment's own secret `name`, as a model provider's key, such as
  `ANTHROPIC_API_KEY`, is asked for where the environment does not set it:
  `:error` where none is held.
  """
  @spec key(t(), String.t()) :: {:ok, String.t()} | :error
  def key(credentials, name)
end
