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

  A credential is a name and whose it is: a user within an org, `{org, user}`,
  since two orgs may each have a user of the same name; an org; or the
  deployment, `nil`.

      WardrikVault.put(vault, "github", {"acme", "jon"}, value: "ghp_xxx")
      WardrikVault.put(vault, "pagerduty", "acme", value: "pd_xxx")
      WardrikVault.put(vault, "linear", nil, value: "lin_xxx")

  ## Resolving

  `Wardrik.Credentials.resolve/3` finds a name for the call's scope, the most specific first: the
  call's user's, then its org's, then the deployment's. The credential it
  answers says whose it is as `:owner`. A name nobody holds answers
  `{:error, :not_found}`.

  A user's own are reached only by their own turns: a turn nobody asked
  for, as a trigger's, or one whose sender the `Wardrik.Grants` of the
  scope's host answers with a grant on that user's agents alone, or on
  every agent. A turn anyone else asked for, someone in the org's channel
  say, reaches the org's and the deployment's, and is asked of the org
  where neither holds the name.

  A name in `:environment` that the node's environment sets is the
  deployment's where no owner the call reaches holds it here, or the vault
  has no key: a tool's key a deployment sets as an environment variable
  resolves so where nobody sealed one.

      WardrikVault.new(store: store, keys: keys, environment: ["SEARCH_API_KEY"])

  A grant is an account its owner connected, and acts as them, so only its
  owner's calls reach it: a user's grant for their calls, an org's for the
  calls of its agents that have no user. A user whose org connected an
  account is asked to connect their own, and a secret the org put reaches
  them as before.

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

  alias Wardrik.AgentID.Prefix
  alias Wardrik.Credential
  alias Wardrik.Scope
  alias WardrikVault.Grants
  alias WardrikVault.Sealed

  @enforce_keys [:store]
  defstruct [:store, keys: [], grants: %Grants.None{}, environment: []]

  @typedoc """
  A vault: the store it keeps credentials in, the base64-encoded keys the
  first of which seals, what it grants, and the names read from the node's
  environment where it holds them for nobody a call reaches.
  """
  @type t() :: %__MODULE__{
          store: WardrikStore.t(),
          keys: [String.t()],
          grants: Grants.t(),
          environment: [String.t()]
        }

  @ns :vault
  # The additional data a value is sealed with: its kind and its key, under
  # the prefix the vault has always written.
  @aad_prefix "wardrik/vault/"
  @version 1
  @key_bytes 32
  @nonce_bytes 12

  @typedoc "Who a credential belongs to: a user within an org, `{org, user}`, an org, any other term the host names, or the deployment, `nil`."
  @type owner() :: term()

  @typedoc "A secret someone put, or a grant someone gave by authorizing."
  @type kind() :: :secret | :grant

  @doc """
  A vault keeping credentials in `:store`.

    * `:keys` - the base64-encoded keys, the first of which seals; none by
      default, so nothing is sealed or unsealed
    * `:grants` - the `WardrikVault.Grants` that renew and ask for grants
    * `:environment` - the names read from the node's environment, as the
      deployment's, where the vault holds them for nobody a call reaches

  Its inspected form shows its store and how many keys it holds, never a
  key.
  """
  @spec new(keyword()) :: t()
  def new(opts) do
    opts = Keyword.validate!(opts, [:store, keys: [], grants: %Grants.None{}, environment: []])
    struct!(__MODULE__, Keyword.update!(opts, :keys, &List.wrap/1))
  end

  @doc false
  def resolve(%__MODULE__{} = vault, name, %Wardrik.Call{scope: %Scope{} = scope})
      when is_binary(name) do
    owners = owners(scope)

    case find(vault, name, owners) do
      {:ok, owner, :secret, secret} ->
        {:ok, Credential.secret(secret, owner: owner)}

      {:ok, owner, :grant, grant} ->
        Grants.renew(vault.grants, name, owner, vault: vault, value: grant)

      {:unreadable, owner} ->
        ask(vault, name, owner)

      :none ->
        environment(vault, name) || ask(vault, name, hd(owners))

      {:error, :no_key} ->
        environment(vault, name) || {:error, :no_key}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp environment(vault, name) do
    with true <- name in vault.environment,
         secret when is_binary(secret) <- System.get_env(name) do
      {:ok, Credential.secret(secret, owner: nil)}
    else
      _unnamed_or_unset -> nil
    end
  end

  @doc false
  def refused(%__MODULE__{} = vault, name, %Wardrik.Call{scope: %Scope{} = scope})
      when is_binary(name) do
    case find(vault, name, owners(scope)) do
      {:ok, owner, :grant, _grant} -> Grants.refused(vault.grants, name, owner, vault: vault)
      _secret_or_none -> :ok
    end
  end

  @doc false
  def key(%__MODULE__{} = vault, name) do
    case lookup(vault, name, nil) do
      {:ok, :secret, secret} -> {:ok, secret}
      _grant_absent_or_unreadable -> :error
    end
  end

  # Whose credentials a scope reaches, the most specific first.
  defp owners(%Scope{} = scope) do
    case Scope.agent_id(scope) do
      %Wardrik.AgentID{user: nil, org: org} ->
        [org, nil]

      %Wardrik.AgentID{org: org, user: user} = id ->
        if theirs?(scope, id), do: [{org, user}, org, nil], else: [org, nil]
    end
  end

  # A turn nobody asked for is the agent's own work, and so its user's.
  defp theirs?(%Scope{sender: nil}, _id), do: true

  defp theirs?(%Scope{sender: sender, host: host}, %Wardrik.AgentID{org: org, user: user} = id) do
    case Wardrik.Host.caller(host, principal: sender, subject: id) do
      {:ok, %Wardrik.Caller{grant: %Wardrik.Grant{scope: scope}}} ->
        scope == Prefix.all() or Prefix.covers?(Prefix.new!(org: org, user: user), scope)

      {:error, _unreached} ->
        false
    end
  end

  # The first of `owners` holding `name`, passing over the grants of any but
  # the first. A grant that no longer unseals is asked for again; a secret
  # that does not is an error.
  defp find(vault, name, [own | _others] = owners) do
    Enum.reduce_while(owners, :none, fn owner, :none ->
      case lookup(vault, name, owner) do
        {:ok, :grant, _value} when owner != own -> {:cont, :none}
        {:error, :grant, _reason} when owner != own -> {:cont, :none}
        {:ok, kind, value} -> {:halt, {:ok, owner, kind, value}}
        {:error, :not_found} -> {:cont, :none}
        {:error, :grant, reason} -> {:halt, unreadable(name, owner, reason)}
        {:error, _kind, reason} -> {:halt, {:error, reason}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp unreadable(name, owner, reason) do
    Logger.warning(
      "#{name} for #{inspect(owner)} cannot be read (#{inspect(reason)}); asking again"
    )

    {:unreadable, owner}
  end

  defp ask(vault, name, owner) do
    if Grants.grants?(vault.grants, name),
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
    prefix = segment(owner) <> "/"

    for key <- WardrikStore.keys(store, @ns, prefix),
        name = String.replace_prefix(key, prefix, ""),
        name != "",
        do: URI.decode(name)
  end

  @doc """
  Every credential written, as `{name, owner}` pairs.

  An owner written as text, such as an org, reads back as that text, and the
  deployment's as `nil`. Any other owner, such as a user's `{org, user}`, is
  written only as a hash of it, and reads back as `:hashed`; `names/2` lists
  what one such owner holds. Reads no credential and needs no key.
  """
  @spec list(t()) :: [{String.t(), owner() | :hashed}]
  def list(%__MODULE__{store: store}) do
    for key <- WardrikStore.keys(store, @ns),
        [owner, name] <- [String.split(key, "/")],
        do: {URI.decode(name), unsegment(owner)}
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
  The key `name` is written under for `owner`, within `namespace/0`. Distinct
  names and owners are written under distinct keys.
  """
  @spec path(String.t(), owner()) :: String.t()
  def path(name, owner) when is_binary(name), do: segment(owner) <> "/" <> segment(name)

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

  # Distinct owners and names always write distinct keys. Text keeps its
  # unreserved characters and percent-encodes the rest, `_` and `~` among
  # them; `_` alone is nobody's; and any other term is `~` and the SHA-256 of
  # its external form.
  defp segment(nil), do: "_"

  defp segment(value) when is_binary(value) or is_atom(value),
    do: value |> to_string() |> URI.encode(&(URI.char_unreserved?(&1) and &1 not in [?_, ?~]))

  defp segment(value),
    do:
      "~" <>
        Base.url_encode64(:crypto.hash(:sha256, :erlang.term_to_binary(value)), padding: false)

  defp unsegment("_"), do: nil
  defp unsegment("~" <> _hash), do: :hashed
  defp unsegment(text), do: URI.decode(text)
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
