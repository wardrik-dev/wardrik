defmodule WardrikHTTP.Tokens do
  @moduledoc """
  The API's tokens as `Wardrik.Tokens` makes, lists and revokes them: each a
  `WardrikHTTP.Token`, kept in the store it holds. A host names it as its
  `Wardrik.Host`'s `:tokens`:

      Wardrik.Host.new(store: store, tokens: %WardrikHTTP.Tokens{store: store})
  """

  alias WardrikHTTP.Token

  @enforce_keys [:store]
  defstruct [:store]

  @type t() :: %__MODULE__{store: WardrikStore.t()}

  # The grant is one already, so only the store failing stops the token
  # being made.
  @doc false
  def create(%__MODULE__{store: store}, name, opts) do
    grant = Keyword.fetch!(opts, :grant)

    {:ok, _secret, _token} =
      Token.create(store, name,
        scope: grant.scope,
        can: grant.can,
        ceiling: grant.ceiling,
        for: opts[:for]
      )
  end

  @doc false
  def list(%__MODULE__{store: store}), do: Token.list(store)

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
