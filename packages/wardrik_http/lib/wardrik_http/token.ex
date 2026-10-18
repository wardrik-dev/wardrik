defmodule WardrikHTTP.Token do
  @moduledoc """
  A bearer token for the HTTP API, and the `Wardrik.Token` it presents.

      token = %Wardrik.Token{principal: jon, scope: [Wardrik.Role.bind([:reader], acme)], expires: expires}
      {:ok, secret, kept} = WardrikHTTP.Token.create(store, "ci", token: token)

  A request presenting it acts with its `Wardrik.Token`: for its principal,
  whoever made it, allowing what its statements allow, until it expires.
  `WardrikHTTP.Tokens` reads `Authorization: Bearer wardrik_…` into a
  `WardrikHTTP.Caller` with `verify/2` and `caller/1`, as the API's
  `WardrikHTTP.Authenticator` unless the listener is given another.

  The secret, `wardrik_` and 32 characters, is answered once and never kept.
  The store each function is handed first holds the token in `:tokens` under
  its `id`, the first 12 hex digits of the SHA-256 of its secret, with the
  whole hash, so the store holds nothing a caller could present. The `id` is
  what `list/1` shows and what `revoke/2` takes.

  `verify/2` reads the token with `WardrikHTTP.Access.get/2`: a revoked token is
  refused at once on every node the revocation reaches, and within a sweep on
  one it does not, and an expired one is refused. `ref/1` is the record a
  socket or a stream holds with `WardrikHTTP.Access.hold/2`, so `revoke/2`
  ends it.
  """

  alias WardrikHTTP.Access
  alias WardrikHTTP.Caller

  @ns :tokens
  @prefix "wardrik_"
  @id_length 12

  @enforce_keys [:id, :name, :token, :hash, :created_at]
  defstruct [:id, :name, :token, :hash, :created_at]

  @type t() :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          token: Wardrik.Token.t(),
          hash: String.t(),
          created_at: DateTime.t()
        }

  @doc "Keeps the `:token` given under the name `name`, and answers the secret that presents it."
  @spec create(WardrikStore.t(), String.t(), token: Wardrik.Token.t()) ::
          {:ok, String.t(), t()} | {:error, term()}
  def create(store, name, opts) when is_binary(name) do
    secret = @prefix <> Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)
    hash = hash(secret)

    token = %__MODULE__{
      id: binary_part(hash, 0, @id_length),
      name: name,
      token: Keyword.fetch!(opts, :token),
      hash: hash,
      created_at: DateTime.utc_now(:second)
    }

    with {:ok, _vsn} <- WardrikStore.put(store, @ns, token.id, token, if_vsn: nil),
         do: {:ok, secret, token}
  end

  @doc """
  The token a secret belongs to, read with `WardrikHTTP.Access.get/2`: `:error` for a
  secret no token has, or one whose token has expired, and
  `{:error, :unavailable}` where the store could not answer.
  """
  @spec verify(WardrikStore.t(), String.t()) :: {:ok, t()} | :error | {:error, :unavailable}
  def verify(store, @prefix <> _rest = secret) do
    hash = hash(secret)

    case Access.get(store, {@ns, binary_part(hash, 0, @id_length)}) do
      {:ok, %__MODULE__{hash: stored} = token} ->
        if Plug.Crypto.secure_compare(stored, hash) and not Wardrik.Token.expired?(token.token),
          do: {:ok, token},
          else: :error

      {:error, :not_found} ->
        :error

      {:error, :unavailable} = unavailable ->
        unavailable
    end
  end

  def verify(_store, _secret), do: :error

  @doc """
  The token `id` names, read as `verify/2` reads one, so a revoked token is
  gone at once: `:error` where there is none, or the store could not answer.
  """
  @spec get(WardrikStore.t(), String.t()) :: {:ok, t()} | :error
  def get(store, id) when is_binary(id) and byte_size(id) == @id_length do
    case Access.get(store, {@ns, id}) do
      {:ok, %__MODULE__{} = token} -> {:ok, token}
      _none -> :error
    end
  end

  def get(_store, _id), do: :error

  @doc "The caller a request presenting `token` comes from."
  @spec caller(t()) :: Caller.t()
  def caller(%__MODULE__{} = token),
    do: %Caller{id: token.id, name: token.name, token: token.token, ref: ref(token)}

  @doc "The record `token` is kept in, for `WardrikHTTP.Access.hold/2`."
  @spec ref(t()) :: Access.ref()
  def ref(%__MODULE__{id: id}), do: {@ns, id}

  @doc "Every token, oldest first."
  @spec list(WardrikStore.t()) :: [t()]
  def list(store) do
    store
    |> WardrikStore.keys(@ns)
    |> Enum.map(&WardrikStore.get(store, @ns, &1))
    |> Enum.filter(&match?(%__MODULE__{}, &1))
    |> Enum.sort_by(& &1.created_at, DateTime)
  end

  @doc """
  Stops the token with `id` working, and ends every socket and stream open on
  it.
  """
  @spec revoke(WardrikStore.t(), String.t()) :: :ok | {:error, :not_found | term()}
  def revoke(store, id) when is_binary(id) and byte_size(id) == @id_length,
    do: Access.revoke(store, {@ns, id})

  def revoke(_store, _id), do: {:error, :not_found}

  defp hash(secret), do: :crypto.hash(:sha256, secret) |> Base.encode16(case: :lower)
end
