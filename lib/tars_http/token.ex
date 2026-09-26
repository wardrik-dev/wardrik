defmodule TarsHTTP.Token do
  @moduledoc """
  A bearer token for the HTTP API, and the `Tars.Grant` it carries.

      {:ok, secret, token} = TarsHTTP.Token.create("ci", "acme/")
      {:ok, secret, token} = TarsHTTP.Token.create("watcher", "acme/ops/", [:read])

  A token grants the actions it was made with, every one where none are
  named, on the agents under its scope; see `Tars.Grant` for both.

  The secret, `tars_` and 32 characters, is answered once and never kept.
  `Tars.Store` holds the token in `:tokens` under its `id`, the first 12 hex
  digits of the SHA-256 of its secret, with the whole hash, so the store holds
  nothing a caller could present. The `id` is what `list/0` shows, what
  `revoke/1` takes, and who a decision made with the token was made by.

  `verify/1` reads the token with `Tars.Access.get/1`: a revoked token is
  refused at once on every node the revocation reaches, and within a sweep on
  one it does not. `ref/1` is the record a socket or a stream holds with
  `Tars.Access.hold/1`, so `revoke/1` ends it.
  """

  alias Tars.Access
  alias Tars.Grant

  @ns :tokens
  @prefix "tars_"
  @id_length 12

  @enforce_keys [:id, :name, :grant, :hash, :created_at]
  defstruct [:id, :name, :grant, :hash, :created_at]

  @type t() :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          grant: Grant.t(),
          hash: String.t(),
          created_at: DateTime.t()
        }

  @doc """
  Makes a token named `name` granting `can` on the agents under `scope`, and
  answers its secret, or a message saying why the grant is not one.
  """
  @spec create(String.t(), String.t(), [Grant.action() | String.t()]) ::
          {:ok, String.t(), t()} | {:error, String.t() | term()}
  def create(name, scope, can \\ Grant.actions()) when is_binary(name) do
    with {:ok, grant} <- Grant.new(scope, can) do
      secret = @prefix <> Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)
      hash = hash(secret)

      token = %__MODULE__{
        id: binary_part(hash, 0, @id_length),
        name: name,
        grant: grant,
        hash: hash,
        created_at: DateTime.utc_now(:second)
      }

      with {:ok, _vsn} <- Tars.Store.put(@ns, token.id, token, if_vsn: nil),
           do: {:ok, secret, token}
    end
  end

  @doc """
  The token a secret belongs to, read with `Tars.Access.get/1`: `:error` for a
  secret no token has, and `{:error, :unavailable}` where the store could not
  answer.
  """
  @spec verify(String.t()) :: {:ok, t()} | :error | {:error, :unavailable}
  def verify(@prefix <> _rest = secret) do
    hash = hash(secret)

    case Access.get({@ns, binary_part(hash, 0, @id_length)}) do
      {:ok, %__MODULE__{hash: stored, grant: %Grant{}} = token} ->
        if Plug.Crypto.secure_compare(stored, hash), do: {:ok, token}, else: :error

      {:ok, _other} ->
        :error

      {:error, :not_found} ->
        :error

      {:error, :unavailable} = unavailable ->
        unavailable
    end
  end

  def verify(_secret), do: :error

  @doc "The record `token` is kept in, for `Tars.Access.hold/1`."
  @spec ref(t()) :: Access.ref()
  def ref(%__MODULE__{id: id}), do: {@ns, id}

  @doc "Every token, oldest first."
  @spec list() :: [t()]
  def list do
    @ns
    |> Tars.Store.keys("")
    |> Enum.map(&Tars.Store.get(@ns, &1))
    |> Enum.filter(&match?(%__MODULE__{grant: %Grant{}}, &1))
    |> Enum.sort_by(& &1.created_at, DateTime)
  end

  @doc """
  Stops the token with `id` working, and ends every socket and stream open on
  it.
  """
  @spec revoke(String.t()) :: :ok | {:error, :not_found | term()}
  def revoke(id) when is_binary(id) and byte_size(id) == @id_length,
    do: Access.revoke({@ns, id})

  def revoke(_id), do: {:error, :not_found}

  defp hash(secret), do: :crypto.hash(:sha256, secret) |> Base.encode16(case: :lower)
end
