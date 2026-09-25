defmodule TarsHTTP.Token do
  @moduledoc """
  A bearer token for the HTTP API, and the agents it reaches.

      {:ok, secret, token} = TarsHTTP.Token.create("ci", "acme/")

  A token reaches the agents whose keys start with its scope: `"acme/"` is one
  org, `"acme/jon/"` one person's agents, and `""` every agent.

  The secret, `tars_` and 32 characters, is answered once and never kept.
  `Tars.Store` holds the token under the SHA-256 of its secret, in `:tokens`,
  so the store holds nothing a caller could present. A token's `id` is the
  first 12 hex digits of that hash: what `list/0` shows, what `revoke/1` takes,
  and who a decision made with the token was made by.
  """

  alias Tars.Store

  @ns :tokens
  @prefix "tars_"
  @id_length 12

  @enforce_keys [:id, :name, :scope, :created_at]
  defstruct [:id, :name, :scope, :created_at]

  @type t() :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          scope: String.t(),
          created_at: DateTime.t()
        }

  @doc "Makes a token named `name` for the agents under `scope`, and answers its secret."
  @spec create(String.t(), String.t()) :: {:ok, String.t(), t()} | {:error, term()}
  def create(name, scope) when is_binary(name) and is_binary(scope) do
    secret = @prefix <> Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)
    hash = hash(secret)

    token = %__MODULE__{
      id: binary_part(hash, 0, @id_length),
      name: name,
      scope: scope,
      created_at: DateTime.utc_now(:second)
    }

    with {:ok, _vsn} <- Store.put(@ns, hash, token, if_vsn: nil), do: {:ok, secret, token}
  end

  @doc "The token a secret belongs to, or `:error`."
  @spec verify(String.t()) :: {:ok, t()} | :error
  def verify(@prefix <> _rest = secret) do
    case Store.get(@ns, hash(secret)) do
      %__MODULE__{} = token -> {:ok, token}
      nil -> :error
    end
  end

  def verify(_secret), do: :error

  @doc "Whether a token reaches the agent under `key`."
  @spec covers?(t(), String.t()) :: boolean()
  def covers?(%__MODULE__{scope: scope}, key) when is_binary(key),
    do: String.starts_with?(key, scope)

  @doc "Every token, oldest first."
  @spec list() :: [t()]
  def list do
    @ns
    |> Store.keys("")
    |> Enum.map(&Store.get(@ns, &1))
    |> Enum.filter(&match?(%__MODULE__{}, &1))
    |> Enum.sort_by(& &1.created_at, DateTime)
  end

  @doc "Stops the token with `id` working."
  @spec revoke(String.t()) :: :ok | {:error, :not_found | term()}
  def revoke(id) when is_binary(id) do
    case Store.keys(@ns, id) do
      [hash] when byte_size(id) == @id_length -> delete(hash)
      _none_or_partial -> {:error, :not_found}
    end
  end

  defp delete(hash) do
    case Store.lookup(@ns, hash) do
      {_token, vsn} -> Store.delete(@ns, hash, if_vsn: vsn)
      nil -> {:error, :not_found}
    end
  end

  defp hash(secret), do: :crypto.hash(:sha256, secret) |> Base.encode16(case: :lower)
end
