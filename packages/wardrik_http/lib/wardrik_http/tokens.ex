defmodule WardrikHTTP.Tokens do
  @moduledoc """
  The API's tokens as `Wardrik.Tokens` makes, lists and revokes them: each a
  `WardrikHTTP.Token`. A host names it as its `Wardrik.Host`'s `:tokens`:

      Wardrik.Host.new(tokens: WardrikHTTP.Tokens)
  """

  @behaviour Wardrik.Tokens

  alias WardrikHTTP.Token

  # The grant is one already, so only the store failing stops the token
  # being made.
  @impl true
  def create(host, name, grant, for) do
    {:ok, _secret, _token} =
      host
      |> Wardrik.Host.store()
      |> Token.create(name, grant.scope, grant.can, ceiling: grant.ceiling, for: for)
  end

  @impl true
  def list(host), do: host |> Wardrik.Host.store() |> Token.list()

  @impl true
  def revoke(host, id) do
    case host |> Wardrik.Host.store() |> Token.revoke(id) do
      :ok -> :ok
      {:error, _reason} -> {:error, :not_found}
    end
  end
end
