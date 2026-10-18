defmodule WardrikHTTP.Tokens do
  @moduledoc """
  The API's tokens as `Wardrik.Tokens` makes, lists and revokes them: each a
  `WardrikHTTP.Token`, kept in the store it holds. A host names it as its
  `Wardrik.Host`'s `:tokens`:

      Wardrik.Host.new(store: store, tokens: %WardrikHTTP.Tokens{store: store})

  It is also the `WardrikHTTP.Authenticator` `WardrikHTTP.Listener` uses
  unless given another: a request presenting `Authorization: Bearer wardrik_…`
  comes from the caller its token makes, `WardrikHTTP.Token.caller/1`.
  """

  alias WardrikHTTP.Token

  @enforce_keys [:store]
  defstruct [:store]

  @type t() :: %__MODULE__{store: WardrikStore.t()}

  # The token is one already, so only the store failing stops it being
  # kept.
  @doc false
  def create(%__MODULE__{store: store}, name, opts) do
    {:ok, secret, token} = Token.create(store, name, token: Keyword.fetch!(opts, :token))
    {:ok, %{entry(token) | secret: secret}}
  end

  @doc false
  def list(%__MODULE__{store: store}), do: store |> Token.list() |> Enum.map(&entry/1)

  defp entry(%Token{} = token) do
    %Wardrik.Tokens.Entry{
      id: token.id,
      name: token.name,
      token: token.token,
      created_at: token.created_at
    }
  end

  @doc false
  def authenticate(%__MODULE__{store: store}, conn) do
    with [header] <- Plug.Conn.get_req_header(conn, "authorization"),
         [scheme, secret] <- String.split(header, " ", parts: 2, trim: true),
         "bearer" <- String.downcase(scheme),
         {:ok, token} <- Token.verify(store, String.trim(secret)) do
      {:ok, Token.caller(token)}
    else
      {:error, :unavailable} = unavailable -> unavailable
      _unknown -> {:error, :unauthorized}
    end
  end

  @doc false
  def revoke(%__MODULE__{store: store}, id) do
    case Token.revoke(store, id) do
      :ok -> :ok
      {:error, _reason} -> {:error, :not_found}
    end
  end
end

defimpl Wardrik.Tokens, for: WardrikHTTP.Tokens do
  defdelegate create(tokens, name, opts), to: WardrikHTTP.Tokens
  defdelegate list(tokens), to: WardrikHTTP.Tokens
  defdelegate revoke(tokens, id), to: WardrikHTTP.Tokens
end

defimpl WardrikHTTP.Authenticator, for: WardrikHTTP.Tokens do
  defdelegate authenticate(tokens, conn), to: WardrikHTTP.Tokens
  def challenge(_tokens), do: ~s(Bearer realm="wardrik")
end
