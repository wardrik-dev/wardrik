defmodule WardrikDaemon.Authenticator do
  @moduledoc """
  Says who sent each HTTP request, from its `Authorization: Bearer` token. It's the daemon's
  `WardrikHTTP.Authenticator`.

      {Wardrik.HTTP, wardrik: name, authenticator: {WardrikDaemon.Authenticator, store}}

    * A `user:` token acts as that user, as `user:acme/@ana`, with its groups.
    * An `agent:` token acts as that agent, as its own tools do.
    * A missing, unknown, revoked or expired token is `:unauthorized`.

  See `WardrikDaemon.Tokens`.
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
         {:ok, scope} <- for_secret(store, wardrik, secret) do
      {:ok, scope}
    else
      _refused ->
        {:error, Error.new(:unauthorized, "Send a token that works, as Authorization: Bearer.")}
    end
  end

  @doc "Returns the scope for a token `secret`. The dashboard stores this secret in its session."
  @spec for_secret(WardrikStore.t(), atom(), String.t()) :: {:ok, Wardrik.Scope.t()} | :error
  def for_secret(store, wardrik, secret) do
    with {:ok, token} <- Tokens.verify(store, secret),
         {:ok, scope} <- scope(store, wardrik, token) do
      {:ok, scope}
    else
      _refused -> :error
    end
  end

  defp scope(_store, wardrik, %Token{subject: "user:" <> id, groups: groups}),
    do: {:ok, Wardrik.as(wardrik, %Principal{id: id, attributes: %{groups: groups}})}

  defp scope(store, wardrik, %Token{subject: "agent:" <> id}) do
    with {:ok, owner} <- Owners.owner(store, id),
         do: {:ok, Wardrik.as(wardrik, owner, actor: {:agent, id})}
  end
end
