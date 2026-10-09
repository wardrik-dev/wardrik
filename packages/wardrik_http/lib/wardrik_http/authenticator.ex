defmodule WardrikHTTP.Authenticator do
  @moduledoc """
  How the HTTP API knows who a request is from: a credential in the request
  read into a `WardrikHTTP.Caller`.

  `WardrikHTTP.Listener` takes the module as `:authenticator`, alone or as
  `{module, opts}`, and `WardrikHTTP.Token` is the one it uses where none is
  given. Every route runs on the caller it answers: its grant decides what
  the request may do, and its principal is whom a decision is recorded as
  made by. A sign-in elsewhere answers a caller the same way, with a grant
  it chose for the person who signed in.
  """

  @doc """
  The caller `conn` comes from: `{:error, :unauthorized}` where it presents
  no credential the module knows, answered `401`, and `{:error, :unavailable}`
  where the credential could not be checked now, answered `503`.
  """
  @callback authenticate(conn :: Plug.Conn.t(), opts :: term()) ::
              {:ok, WardrikHTTP.Caller.t()} | {:error, :unauthorized | :unavailable}

  @doc "What a `401` asks for, as its `WWW-Authenticate` header."
  @callback challenge(opts :: term()) :: String.t()
end
