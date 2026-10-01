defmodule WardrikVault do
  @moduledoc """
  Where credentials are kept, sealed with a key the deployment holds, in
  `Wardrik.Store`, and the `Wardrik.Credential` resolver that finds them.

      config :wardrik, WardrikVault, keys: [System.fetch_env!("WARDRIK_VAULT_KEY")]

      Wardrik.Fleet.spawn(key, config: config, credentials: WardrikVault)

  Nothing else is needed: no database, no broker, no network. A single binary
  can hold its users' credentials across restarts and across the nodes the
  store is replicated to.

  A credential is a name and whose it is: a user within an org, `{org, user}`,
  since two orgs may each have a user of the same name; an org; or the
  deployment, `nil`.

      WardrikVault.put("github", {"acme", "jon"}, "ghp_xxx")
      WardrikVault.put("pagerduty", "acme", "pd_xxx")
      WardrikVault.put("linear", nil, "lin_xxx")

  ## Resolving

  `resolve/2` finds a name for the call's scope, the most specific first: the
  call's user's, then its org's, then the deployment's. The credential it
  answers says whose it is as `:owner`. A name nobody holds answers
  `{:error, :not_found}`.

  ## Grants

  A credential is a secret someone put here, or a grant: what a user, or an
  org, gave by authorizing an account, kept here like any other and renewed by
  the module `:grants` names, such as `WardrikOAuth`:

      config :wardrik, WardrikVault, keys: [...], grants: WardrikOAuth

  A grant `resolve/2` finds is handed to that module to answer, renewing it
  where it has run out. A name nobody holds that the module can grant is asked
  for, of the call's user, or of its org where the call has no user, and the
  call parks on where they authorize. See `WardrikVault.Grants`.

  ## Keys

  Credentials are sealed with AES-256-GCM. `:keys` is a list of base64-encoded
  32-byte keys; the first seals, and any of them may unseal, which is what
  makes rotation possible: put the new key first, leave the old one behind it
  until nothing needs it.

      WardrikVault.generate_key()
      #=> "hX2...=="

  Without a key nothing is written and nothing is read: every call answers
  `{:error, :no_key}` rather than falling back to plaintext.

  The key seals the value only. Which owner has a credential of which name,
  and whether it is a grant, is visible to anyone who can read the store, and
  the store is the customer's. Two owners, or two names, never share a key:
  see `path/2`.

  ## Extracting this package

  When the vault moves out into `wardrik_vault`, `lib/wardrik_vault/` and
  `test/wardrik_vault/` move into a project declaring `{:wardrik, "~> 0.1"}`, and the
  setting becomes `config :wardrik_vault, keys: [...]`.
  """

  @behaviour Wardrik.Credential

  require Logger

  alias Wardrik.Credential
  alias Wardrik.Scope
  alias Wardrik.Store
  alias WardrikVault.Config
  alias WardrikVault.Sealed

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

  @impl Wardrik.Credential
  def resolve(name, %Wardrik.Call{scope: %Scope{} = scope} = call) when is_binary(name) do
    owners = owners(scope)

    case find(name, owners) do
      {:ok, owner, :secret, secret} -> {:ok, Credential.secret(secret, owner: owner)}
      {:ok, owner, :grant, grant} -> Config.grants().renew(name, owner, grant, call)
      {:unreadable, owner} -> ask(name, owner, call)
      :none -> ask(name, hd(owners), call)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Tells the grants module that the grant last resolved for `name` was refused."
  @impl Wardrik.Credential
  def refused(name, %Wardrik.Call{scope: %Scope{} = scope} = call) when is_binary(name) do
    case find(name, owners(scope)) do
      {:ok, owner, :grant, _grant} -> Config.grants().refused(name, owner, call)
      _secret_or_none -> :ok
    end
  end

  # Whose credentials a scope reaches, the most specific first.
  defp owners(%Scope{org: org, user: user}) do
    Enum.reject([user && {org, user}, org], &is_nil/1) ++ [nil]
  end

  # The first of `owners` holding `name`. A grant that no longer unseals is
  # asked for again; a secret that does not is an error.
  defp find(name, owners) do
    Enum.reduce_while(owners, :none, fn owner, :none ->
      case lookup(name, owner) do
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

  defp ask(name, owner, call) do
    grants = Config.grants()

    if grants && grants.grants?(name),
      do: grants.ask(name, owner, call),
      else: {:error, :not_found}
  end

  @doc """
  Seals `value` and writes it down as `name` for `owner`, a secret unless
  `kind: :grant` says it is one.

  Overwrites whatever was there, so authorizing again is a `put/4`.
  """
  @spec put(String.t(), owner(), String.t(), keyword()) :: :ok | {:error, term()}
  def put(name, owner, value, opts \\ []) when is_binary(name) and is_binary(value) do
    kind = Keyword.get(opts, :kind, :secret)

    with {:ok, key} <- sealing_key() do
      path = path(name, owner)
      write(path, seal(key, path, kind, value))
    end
  end

  @doc "Unseals what is written as `name` for `owner`, a secret or a grant."
  @spec fetch(String.t(), owner()) :: {:ok, String.t()} | {:error, term()}
  def fetch(name, owner) do
    case lookup(name, owner) do
      {:ok, _kind, value} -> {:ok, value}
      {:error, _kind, reason} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  What is written as `name` for `owner`, with its kind, or why not: `:not_found`
  where nothing is, and the kind with the reason where it does not unseal.
  """
  @spec lookup(String.t(), owner()) ::
          {:ok, kind(), String.t()} | {:error, term()} | {:error, kind(), term()}
  def lookup(name, owner) do
    path = path(name, owner)

    with {:ok, keys} <- unsealing_keys(),
         {:ok, %Sealed{} = sealed} <- read(path) do
      case unseal(keys, path, sealed) do
        {:ok, value} -> {:ok, sealed.kind, value}
        {:error, reason} -> {:error, sealed.kind, reason}
      end
    end
  end

  @doc "Whether anything is written as `name` for `owner`."
  @spec has?(String.t(), owner()) :: boolean()
  def has?(name, owner), do: match?({:ok, _value}, fetch(name, owner))

  @doc "Removes what is written as `name` for `owner`. Removing nothing is still `:ok`."
  @spec forget(String.t(), owner()) :: :ok | {:error, term()}
  def forget(name, owner), do: Store.delete(@ns, path(name, owner))

  @doc """
  The names `owner` holds credentials of.

  Reads no credential and needs no key.
  """
  @spec names(owner()) :: [String.t()]
  def names(owner) do
    prefix = segment(owner) <> "/"

    for key <- Store.keys(@ns, prefix),
        name = String.replace_prefix(key, prefix, ""),
        name != "",
        do: URI.decode(name)
  end

  @doc """
  Every credential written, as `{name, owner}` pairs.

  An owner written as text, such as an org, reads back as that text, and the
  deployment's as `nil`. Any other owner, such as a user's `{org, user}`, is
  written only as a hash of it, and reads back as `:hashed`; `names/1` lists
  what one such owner holds. Reads no credential and needs no key.
  """
  @spec list() :: [{String.t(), owner() | :hashed}]
  def list do
    for key <- Store.keys(@ns),
        [owner, name] <- [String.split(key, "/")],
        do: {URI.decode(name), unsegment(owner)}
  end

  @doc "A new key, base64-encoded, for `:keys`."
  @spec generate_key() :: String.t()
  def generate_key, do: @key_bytes |> :crypto.strong_rand_bytes() |> Base.encode64()

  @doc "Whether `key` is one `:keys` can hold: #{@key_bytes} bytes, base64-encoded."
  @spec key?(term()) :: boolean()
  def key?(key), do: decode_key(key) != []

  @doc "Whether this deployment gave the vault a key to work with."
  @spec ready?() :: boolean()
  def ready?, do: match?({:ok, _key}, sealing_key())

  @doc "The namespace secrets are written under in `Wardrik.Store`."
  @spec namespace() :: Store.ns()
  def namespace, do: @ns

  @doc """
  The key `name` is written under for `owner`, within `namespace/0`. Distinct
  names and owners are written under distinct keys.
  """
  @spec path(String.t(), owner()) :: String.t()
  def path(name, owner) when is_binary(name), do: segment(owner) <> "/" <> segment(name)

  defp write(path, %Sealed{} = sealed) do
    case Store.put(@ns, path, sealed) do
      {:ok, _vsn} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp read(path) do
    case Store.lookup(@ns, path) do
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

  defp sealing_key do
    case unsealing_keys() do
      {:ok, [key | _rest]} -> {:ok, key}
      {:error, reason} -> {:error, reason}
    end
  end

  defp unsealing_keys do
    case Enum.flat_map(configured_keys(), &decode_key/1) do
      [] -> {:error, :no_key}
      keys -> {:ok, keys}
    end
  end

  defp configured_keys, do: Config.keys()

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
