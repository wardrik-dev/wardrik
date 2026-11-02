defmodule WardrikDaemon.Authenticator do
  @moduledoc """
  Says who each HTTP request comes from, by the token it's sent with as `Authorization: Bearer`.
  It's the daemon's `WardrikHTTP.Authenticator`. See `WardrikDaemon.Tokens`.

    * A `user:ID` token acts as the principal `ID`, with its groups as the principal's `:groups`
      attribute.
    * An `agent:ID` token acts as the agent, by its ID, for its owner, as its own tools do.

  A missing, unknown, revoked or expired token is `:unauthorized`.

      {Wardrik.HTTP, wardrik: name, authenticator: {WardrikDaemon.Authenticator, store}}

  `store` is the daemon's own scope of the store, where `WardrikDaemon.Tokens` keeps them.
  """

  @behaviour WardrikHTTP.Authenticator

  alias Wardrik.Error
  alias WardrikCore.Principal
  alias WardrikDaemon.Owners
  alias WardrikDaemon.Tokens
  alias WardrikDaemon.Tokens.Token
  alias WardrikHTTP.Authenticator.Request

  @impl WardrikHTTP.Authenticator
  @spec authenticate(Request.t(), WardrikStore.t()) ::
          {:ok, Wardrik.Scope.t()} | {:error, Error.t()}
  def authenticate(%Request{conn: conn, wardrik: wardrik}, store) do
    with ["Bearer " <> secret] <- Plug.Conn.get_req_header(conn, "authorization"),
         {:ok, token} <- Tokens.verify(store, secret),
         {:ok, scope} <- scope(store, wardrik, token) do
      {:ok, scope}
    else
      _refused ->
        {:error, Error.new(:unauthorized, "Send a token that works, as Authorization: Bearer.")}
    end
  end

  defp scope(_store, wardrik, %Token{subject: "user:" <> id, groups: groups}),
    do: {:ok, Wardrik.as(wardrik, %Principal{id: id, attributes: %{groups: groups}})}

  defp scope(store, wardrik, %Token{subject: "agent:" <> id}) do
    with {:ok, owner} <- Owners.owner(store, id),
         do: {:ok, Wardrik.as(wardrik, owner, actor: {:agent, id})}
  end
end
