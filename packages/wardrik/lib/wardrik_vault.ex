defmodule WardrikVault do
  @moduledoc """
  Where credentials are kept, sealed with a key the deployment holds, in a
  store, and the `Wardrik.Credentials` that find them for a call.

  A vault is a value, holding its store, its keys and what it grants, and
  every function is handed it first. A host names it once as its
  `:credentials`, so every agent's calls resolve through it:

      vault = WardrikVault.new(store: store, keys: [System.fetch_env!("WARDRIK_VAULT_KEY")])
      host = Wardrik.Host.new(store: store, credentials: vault)

  Nothing else is needed: no database, no broker, no network. A single binary
  can hold its users' credentials across restarts and across the nodes the
  store is replicated to.

  A credential is a name and whose it is, a namespace as `Wardrik.Resource`
  names one: a user within an org, `acme/@jon`, since two orgs may each have
  a user of the same name; an org, `acme`; or the deployment, `deployment`.

      jon = Wardrik.Resource.parse!("acme/@jon")
      WardrikVault.put(vault, "github", jon, value: "ghp_xxx")
      WardrikVault.put(vault, "pagerduty", Wardrik.Resource.parse!("acme"), value: "pd_xxx")
      WardrikVault.put(vault, "linear", Wardrik.Resource.deployment(), value: "lin_xxx")

  ## Resolving

  `Wardrik.Credentials.resolve/3` finds a name for the agent a call is made
  by, as its owner holds it: the user it works for, within its org, or its
  org, for an agent that works for nobody. Nothing falls back from one
  owner to another: a user's agent never reads its org's, and an org's
  agent never reads a user's, so whoever may ask an agent may use what its
  owner holds and nothing else. A name the owner does not hold answers
  `{:error, :not_found}`. The credential answered says whose it is as
  `:owner`. The deployment's own secrets reach no agent's calls: a key
  every org's agents use is sealed for each org.

  A grant is an account its owner connected, and acts as them, so only its
  owner's agents reach it. A name the owner does not hold that the vault's
  grants can grant is asked of the owner, so a user's agent asks them to
  connect their own.

  ## Grants

  A credential is a secret someone put here, or a grant: what a user, or an
  org, gave by authorizing an account, kept here like any other and renewed by
  the `WardrikVault.Grants` `:grants` holds, such as `WardrikOAuth`'s:

      WardrikVault.new(store: store, keys: keys, grants: oauth)

  A grant a resolve finds is handed to them to answer, renewing it where it
  has run out. A name nobody holds that they can grant is asked for, of the
  call's user, or of its org where the call has no user, and the call parks
  on where they authorize, until they say they have.

  ## Keys

  Credentials are sealed with AES-256-GCM. `:keys` is a list of base64-encoded
  32-byte keys; the first seals, and any of them may unseal, which is what
  makes rotation possible: put the new key first, leave the old one behind it
  until nothing needs it.

      WardrikVault.generate_key()
      #=> "hX2...=="

  Without a key nothing is written and nothing is read: every call answers
  `{:error, :no_key}` rather than falling back to plaintext.

  ## Model providers' keys

  `Wardrik.Credentials.key/2` answers a provider's key, such as
  `ANTHROPIC_API_KEY`, as the deployment's secret of that name, so a model
  call takes it where the environment sets none; see `Wardrik.LLM.Key`.

  The key seals the value only. Which owner has a credential of which name,
  and whether it is a grant, is visible to anyone who can read the store, and
  the store is the customer's. Two owners, or two names, never share a key:
  see `path/2`.
  """

  require Logger

  alias Wardrik.AgentID
  alias Wardrik.Credential
  alias Wardrik.Resource
  alias Wardrik.Run
  alias WardrikVault.Grants
  alias WardrikVault.Sealed

  @enforce_keys [:store]
  defstruct [:store, keys: [], grants: %Grants.None{}]

  @typedoc """
  A vault: the store it keeps credentials in, the base64-encoded keys the
  first of which seals, and what it grants.
  """
  @type t() :: %__MODULE__{store: WardrikStore.t(), keys: [String.t()], grants: Grants.t()}

  @ns :vault
  # The additional data a value is sealed with: its kind and its key, under
  # the prefix the vault has always written.
  @aad_prefix "wardrik/vault/"
  @version 1
  @key_bytes 32
  @nonce_bytes 12

  @typedoc "Who a credential belongs to: a user within an org, an org, or the deployment."
  @type owner() :: Resource.t()

  @typedoc "A secret someone put, or a grant someone gave by authorizing."
  @type kind() :: :secret | :grant

  @doc """
  A vault keeping credentials in `:store`.

    * `:keys` - the base64-encoded keys, the first of which seals; none by
      default, so nothing is sealed or unsealed
    * `:grants` - the `WardrikVault.Grants` that renew and ask for grants

  Its inspected form shows its store and how many keys it holds, never a
  key.
  """
  @spec new(keyword()) :: t()
  def new(opts) do
    opts = Keyword.validate!(opts, [:store, keys: [], grants: %Grants.None{}])
    struct!(__MODULE__, Keyword.update!(opts, :keys, &List.wrap/1))
  end

  @doc false
  def resolve(%__MODULE__{} = vault, name, %Wardrik.Call{run: %Run{} = run})
      when is_binary(name) do
    owner = owner(run)

    case lookup(vault, name, owner) do
      {:ok, :secret, secret} ->
        {:ok, Credential.secret(secret, owner: owner)}

      {:ok, :grant, grant} ->
        Grants.renew(vault.grants, name, owner, vault: vault, value: grant)

      {:error, :grant, reason} ->
        unreadable(name, owner, reason)
        ask(vault, name, owner)

      {:error, :not_found} ->
        ask(vault, name, owner)

      {:error, _kind, reason} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc false
  def refused(%__MODULE__{} = vault, name, %Wardrik.Call{run: %Run{} = run})
      when is_binary(name) do
    owner = owner(run)

    case lookup(vault, name, owner) do
      {:ok, :grant, _grant} -> Grants.refused(vault.grants, name, owner, vault: vault)
      _secret_or_none -> :ok
    end
  end

  @doc false
  def key(%__MODULE__{} = vault, name) do
    case lookup(vault, name, Resource.deployment()) do
      {:ok, :secret, secret} -> {:ok, secret}
      _grant_absent_or_unreadable -> :error
    end
  end

  # The owner of the agent a run is for.
  defp owner(%Run{} = run), do: Resource.owner(AgentID.resource(Run.agent_id(run)))

  defp unreadable(name, owner, reason) do
    Logger.warning(
      "#{name} for #{inspect(owner)} cannot be read (#{inspect(reason)}); asking again"
    )
  end

  defp ask(vault, name, owner) do
    if Grants.grants?(vault.grants, name, owner),
      do: Grants.ask(vault.grants, name, owner, vault: vault),
      else: {:error, :not_found}
  end

  @doc """
  Seals the `:value` `opts` name and writes it down as `name` for `owner`, a
  secret unless `kind: :grant` says it is one.

  Overwrites whatever was there, so authorizing again is a `put/4`.
  """
  @spec put(t(), String.t(), owner(), value: String.t(), kind: kind()) :: :ok | {:error, term()}
  def put(%__MODULE__{} = vault, name, owner, opts) when is_binary(name) do
    opts = Keyword.validate!(opts, [:value, kind: :secret])
    value = Keyword.fetch!(opts, :value)

    with {:ok, key} <- sealing_key(vault) do
      path = path(name, owner)
      write(vault.store, path, seal(key, path, opts[:kind], value))
    end
  end

  @doc "Unseals what is written as `name` for `owner`, a secret or a grant."
  @spec fetch(t(), String.t(), owner()) :: {:ok, String.t()} | {:error, term()}
  def fetch(vault, name, owner) do
    case lookup(vault, name, owner) do
      {:ok, _kind, value} -> {:ok, value}
      {:error, _kind, reason} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  What is written as `name` for `owner`, with its kind, or why not: `:not_found`
  where nothing is, and the kind with the reason where it does not unseal.
  """
  @spec lookup(t(), String.t(), owner()) ::
          {:ok, kind(), String.t()} | {:error, term()} | {:error, kind(), term()}
  def lookup(%__MODULE__{} = vault, name, owner) do
    path = path(name, owner)

    with {:ok, keys} <- unsealing_keys(vault),
         {:ok, %Sealed{} = sealed} <- read(vault.store, path) do
      case unseal(keys, path, sealed) do
        {:ok, value} -> {:ok, sealed.kind, value}
        {:error, reason} -> {:error, sealed.kind, reason}
      end
    end
  end

  @doc "Whether anything is written as `name` for `owner`."
  @spec has?(t(), String.t(), owner()) :: boolean()
  def has?(vault, name, owner), do: match?({:ok, _value}, fetch(vault, name, owner))

  @doc "Removes what is written as `name` for `owner`. Removing nothing is still `:ok`."
  @spec forget(t(), String.t(), owner()) :: :ok | {:error, term()}
  def forget(%__MODULE__{store: store}, name, owner),
    do: WardrikStore.delete(store, @ns, path(name, owner))

  @doc """
  The names `owner` holds credentials of.

  Reads no credential and needs no key.
  """
  @spec names(t(), owner()) :: [String.t()]
  def names(%__MODULE__{store: store}, owner) do
    prefix = "#{owner}/secret/"
    for key <- WardrikStore.keys(store, @ns, prefix), do: String.replace_prefix(key, prefix, "")
  end

  @doc "Every credential written, as `{name, owner}` pairs. Reads no credential and needs no key."
  @spec list(t()) :: [{String.t(), owner()}]
  def list(%__MODULE__{store: store}) do
    for key <- WardrikStore.keys(store, @ns),
        secret = Resource.parse!(key),
        do: {Resource.basename(secret), Resource.owner(secret)}
  end

  @doc "A new key, base64-encoded, for `:keys`."
  @spec generate_key() :: String.t()
  def generate_key, do: @key_bytes |> :crypto.strong_rand_bytes() |> Base.encode64()

  @doc "Whether `key` is one `:keys` can hold: #{@key_bytes} bytes, base64-encoded."
  @spec key?(term()) :: boolean()
  def key?(key), do: decode_key(key) != []

  @doc "Whether `vault` holds a key it can work with."
  @spec ready?(t()) :: boolean()
  def ready?(vault), do: match?({:ok, _key}, sealing_key(vault))

  @doc "Whether `vault` was given a key at all, usable or not; `ready?/1` says whether it is usable."
  @spec configured?(t()) :: boolean()
  def configured?(%__MODULE__{keys: keys}), do: keys != []

  @doc "The namespace secrets are written under in `WardrikStore`."
  @spec namespace() :: WardrikStore.ns()
  def namespace, do: @ns

  @doc """
  The key `name` is written under for `owner`, within `namespace/0`: the
  secret's resource name, as `acme/@jon/secret/github`, so distinct names and
  owners are written under distinct keys. A name is a segment, as
  `Wardrik.AgentID` writes one; any other raises `ArgumentError`.
  """
  @spec path(String.t(), owner()) :: String.t()
  def path(name, owner) when is_binary(name), do: to_string(Resource.new(owner, secret: name))

  defp write(store, path, %Sealed{} = sealed) do
    case WardrikStore.put(store, @ns, path, sealed) do
      {:ok, _vsn} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp read(store, path) do
    case WardrikStore.lookup(store, @ns, path) do
      {%Sealed{} = sealed, _vsn} -> {:ok, sealed}
      nil -> {:error, :not_found}
      {other, _vsn} -> {:error, {:unreadable, other}}
    end
  end

  # The kind and the path are authenticated along with the value, so a sealed
  # value moved to another owner's key, or passed off as another kind, will
  # not unseal.
  defp seal(key, path, kind, value) do
    nonce = :crypto.strong_rand_bytes(@nonce_bytes)

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(:aes_256_gcm, key, nonce, value, aad(kind, path), true)

    %Sealed{version: @version, kind: kind, nonce: nonce, ciphertext: ciphertext, tag: tag}
  end

  defp aad(:secret, path), do: @aad_prefix <> path
  defp aad(kind, path), do: @aad_prefix <> Atom.to_string(kind) <> ":" <> path

  defp unseal(keys, path, %Sealed{version: @version} = sealed) do
    aad = aad(sealed.kind, path)

    Enum.reduce_while(keys, {:error, :undecipherable}, fn key, answer ->
      case :crypto.crypto_one_time_aead(
             :aes_256_gcm,
             key,
             sealed.nonce,
             sealed.ciphertext,
             aad,
             sealed.tag,
             false
           ) do
        :error -> {:cont, answer}
        secret -> {:halt, {:ok, secret}}
      end
    end)
  end

  defp unseal(_keys, _path, %Sealed{version: version}), do: {:error, {:unknown_version, version}}

  defp sealing_key(vault) do
    case unsealing_keys(vault) do
      {:ok, [key | _rest]} -> {:ok, key}
      {:error, reason} -> {:error, reason}
    end
  end

  defp unsealing_keys(%__MODULE__{keys: keys}) do
    case Enum.flat_map(keys, &decode_key/1) do
      [] -> {:error, :no_key}
      keys -> {:ok, keys}
    end
  end

  defp decode_key(key) when is_binary(key) do
    case Base.decode64(key) do
      {:ok, <<decoded::binary-size(@key_bytes)>>} -> [decoded]
      _other -> []
    end
  end

  defp decode_key(_key), do: []
end

defimpl Wardrik.Credentials, for: WardrikVault do
  defdelegate resolve(vault, ref, call), to: WardrikVault
  defdelegate refused(vault, ref, call), to: WardrikVault
  defdelegate key(vault, name), to: WardrikVault
end

defimpl Inspect, for: WardrikVault do
  def inspect(%WardrikVault{store: store, keys: keys}, opts) do
    Inspect.Algebra.concat([
      "#WardrikVault<",
      Inspect.Algebra.to_doc(store, opts),
      ", #{length(keys)} keys>"
    ])
  end
end
