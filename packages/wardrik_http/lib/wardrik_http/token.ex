defmodule WardrikHTTP.Token do
  @moduledoc """
  A bearer token for the HTTP API, and the `Wardrik.Grant` it carries.

      acme = Wardrik.AgentID.Prefix.new!(org: "acme")
      {:ok, secret, token} = WardrikHTTP.Token.create(store, "ci", scope: acme, can: [:define], ceiling: hooks)
      {:ok, secret, token} = WardrikHTTP.Token.create(store, "watcher", scope: Wardrik.AgentID.Prefix.parse!("acme/@jon/"), can: [:read])

  A token grants the actions it was made with, every one where none are
  named, on the agents under its scope; see `Wardrik.Grant` for both. It acts
  for the `Wardrik.Principal` it was made `:for`, such as a person, and for
  itself where it names none: a decision made with it is recorded as that
  principal's.

  It is the `WardrikHTTP.Authenticator` the API uses unless told otherwise,
  reading `Authorization: Bearer wardrik_…` into a `WardrikHTTP.Caller`, from
  the store of the listener's host.

  A token that can `:define` is made with a `:ceiling`, the hooks every agent
  it defines is held to ahead of the definition's own, or with `ceiling: []`
  to hold them to nothing more; it is never left unlimited by omission.
  `WardrikHTTP.Router` puts the ceiling in place as it defines an agent. A
  token stored before tokens had ceilings reads as one made with `[]`.

  The secret, `wardrik_` and 32 characters, is answered once and never kept.
  The store each function is handed first holds the token in `:tokens` under
  its `id`, the first 12 hex digits of the SHA-256 of its secret, with the
  whole hash, so the store holds nothing a caller could present. The `id` is
  what `list/1` shows and what `revoke/2` takes.

  `verify/2` reads the token with `WardrikHTTP.Access.get/2`: a revoked token is
  refused at once on every node the revocation reaches, and within a sweep on
  one it does not. `ref/1` is the record a socket or a stream holds with
  `WardrikHTTP.Access.hold/2`, so `revoke/2` ends it.
  """

  @behaviour WardrikHTTP.Authenticator

  alias Wardrik.Grant
  alias Wardrik.Principal
  alias WardrikHTTP.Access
  alias WardrikHTTP.Caller

  @ns :tokens
  @prefix "wardrik_"
  @id_length 12

  @enforce_keys [:id, :name, :grant, :hash, :created_at]
  defstruct [:id, :name, :grant, :hash, :created_at, :principal]

  @type t() :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          grant: Grant.t(),
          hash: String.t(),
          created_at: DateTime.t(),
          principal: Principal.t() | nil
        }

  @doc """
  Makes a token named `name` and answers its secret, or a message saying why
  the grant is not one.

    * `:scope` - the agents it reaches, a `Wardrik.AgentID.Prefix`; required
    * `:can` - what it may do there, every action unless given
    * `:ceiling` - the grant's ceiling, which a token that can `:define` must
      be given
    * `:for` - the `Wardrik.Principal` it acts for
  """
  @spec create(WardrikStore.t(), String.t(),
          scope: Wardrik.AgentID.Prefix.t(),
          can: [Grant.action() | String.t()],
          ceiling: [Wardrik.Hook.t()],
          for: Principal.t()
        ) ::
          {:ok, String.t(), t()} | {:error, String.t() | term()}
  def create(store, name, opts) when is_binary(name) do
    opts = Keyword.validate!(opts, [:scope, :ceiling, :for, can: Grant.actions()])
    scope = Keyword.fetch!(opts, :scope)
    can = Keyword.fetch!(opts, :can)

    with {:ok, grant} <- Grant.new(scope, can, Keyword.get(opts, :ceiling, [])),
         :ok <- chosen(grant, opts) do
      secret = @prefix <> Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)
      hash = hash(secret)

      token = %__MODULE__{
        id: binary_part(hash, 0, @id_length),
        name: name,
        grant: grant,
        hash: hash,
        created_at: DateTime.utc_now(:second),
        principal: Keyword.get(opts, :for)
      }

      with {:ok, _vsn} <- WardrikStore.put(store, @ns, token.id, token, if_vsn: nil),
           do: {:ok, secret, token}
    end
  end

  @doc """
  The token a secret belongs to, read with `WardrikHTTP.Access.get/2`: `:error` for a
  secret no token has, and `{:error, :unavailable}` where the store could not
  answer.
  """
  @spec verify(WardrikStore.t(), String.t()) :: {:ok, t()} | :error | {:error, :unavailable}
  def verify(store, @prefix <> _rest = secret) do
    hash = hash(secret)

    case Access.get(store, {@ns, binary_part(hash, 0, @id_length)}) do
      {:ok, %__MODULE__{hash: stored, grant: %Grant{}} = token} ->
        if Plug.Crypto.secure_compare(stored, hash), do: {:ok, current(token)}, else: :error

      {:ok, _other} ->
        :error

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
      {:ok, %__MODULE__{grant: %Grant{}} = token} -> {:ok, current(token)}
      _none -> :error
    end
  end

  def get(_store, _id), do: :error

  # A token that can define says what its agents are held to, even nothing.
  defp chosen(grant, opts) do
    if :define in grant.can and not Keyword.has_key?(opts, :ceiling),
      do:
        {:error,
         "A token that can define agents is made with a ceiling, or with none, ceiling: []"},
      else: :ok
  end

  # A grant stored before grants had ceilings has none, and a token stored
  # before tokens acted for anyone acts for itself.
  defp current(%__MODULE__{grant: grant} = token),
    do:
      struct(__MODULE__, %{Map.from_struct(token) | grant: struct(Grant, Map.from_struct(grant))})

  @doc "Whom `token` acts for: the principal it was made for, or itself."
  @spec principal(t()) :: Principal.t()
  def principal(%__MODULE__{principal: nil} = token),
    do: Principal.new(:token, token.id, name: token.name)

  def principal(%__MODULE__{principal: principal}), do: principal

  @doc "The caller a request presenting `token` comes from."
  @spec caller(t()) :: Caller.t()
  def caller(%__MODULE__{} = token) do
    %Caller{
      id: token.id,
      name: token.name,
      principal: principal(token),
      grant: token.grant,
      ref: ref(token)
    }
  end

  @impl WardrikHTTP.Authenticator
  def authenticate(conn, _opts) do
    store = conn.assigns.options |> Keyword.fetch!(:host) |> Wardrik.Host.store()

    with [header] <- Plug.Conn.get_req_header(conn, "authorization"),
         [scheme, secret] <- String.split(header, " ", parts: 2, trim: true),
         "bearer" <- String.downcase(scheme),
         {:ok, token} <- verify(store, String.trim(secret)) do
      {:ok, caller(token)}
    else
      {:error, :unavailable} = unavailable -> unavailable
      _unknown -> {:error, :unauthorized}
    end
  end

  @impl WardrikHTTP.Authenticator
  def challenge(_opts), do: ~s(Bearer realm="wardrik")

  @doc "The record `token` is kept in, for `WardrikHTTP.Access.hold/2`."
  @spec ref(t()) :: Access.ref()
  def ref(%__MODULE__{id: id}), do: {@ns, id}

  @doc "Every token, oldest first."
  @spec list(WardrikStore.t()) :: [t()]
  def list(store) do
    store
    |> WardrikStore.keys(@ns)
    |> Enum.map(&WardrikStore.get(store, @ns, &1))
    |> Enum.filter(&match?(%__MODULE__{grant: %Grant{}}, &1))
    |> Enum.map(&current/1)
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
