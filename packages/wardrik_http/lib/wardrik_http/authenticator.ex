defprotocol WardrikHTTP.Authenticator do
  @moduledoc """
  How the HTTP API knows who a request is from: a credential in the request
  read into a `WardrikHTTP.Caller`.

  `WardrikHTTP.Listener` takes one as `:authenticator`, a struct implementing
  this protocol, and uses `%WardrikHTTP.Tokens{}` over its host's store where
  none is given. Every route runs on the caller it answers: its grant decides
  what the request may do, and its principal is whom a decision is recorded
  as made by. A sign-in elsewhere answers a caller the same way, with a grant
  it chose for the person who signed in:

      defmodule MyApp.Session do
        defstruct [:secret]
      end

      defimpl WardrikHTTP.Authenticator, for: MyApp.Session do
        def authenticate(session, conn), do: MyApp.Session.caller(session, conn)
        def challenge(_session), do: ~s(Bearer realm="myapp")
      end
  """

  @doc """
  The caller `conn` comes from: `{:error, :unauthorized}` where it presents
  no credential the authenticator knows, answered `401`, and
  `{:error, :unavailable}` where the credential could not be checked now,
  answered `503`.
  """
  @spec authenticate(t(), Plug.Conn.t()) ::
          {:ok, WardrikHTTP.Caller.t()} | {:error, :unauthorized | :unavailable}
  def authenticate(authenticator, conn)

  @doc "What a `401` asks for, as its `WWW-Authenticate` header."
  @spec challenge(t()) :: String.t()
  def challenge(authenticator)
end
