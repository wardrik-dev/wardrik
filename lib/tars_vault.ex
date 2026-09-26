defmodule TarsVault do
  @moduledoc """
  A `Tars.Credential` resolver that keeps secrets in `Tars.Store`, sealed
  with a key the deployment holds.

      config :tars, TarsVault, keys: [System.fetch_env!("TARS_VAULT_KEY")]

      Tars.Fleet.spawn("assistant", config: config, credentials: TarsVault)

  Nothing else is needed: no database, no broker, no network. A single binary
  can hold a user's tokens across restarts and across the nodes the store is
  replicated to.

      TarsVault.put({:user, "github"}, "jon", "ghp_xxx")
      TarsVault.fetch({:user, "github"}, "jon")
      TarsVault.forget({:user, "github"}, "jon")

  A reference resolves against the scope it is asked for: `{:user, name}` reads
  the secret belonging to `scope.user`, `{:org, name}` to `scope.org`, and
  `{:named, name}` one the deployment put there itself. A secret that is not
  there answers `{:error, :not_found}`, which a tool reads as "not connected
  yet". `TarsOAuth` wraps this with somewhere for the user to go.

  ## Keys

  Secrets are sealed with AES-256-GCM. `:keys` is a list of base64-encoded
  32-byte keys; the first seals, and any of them may unseal, which is what
  makes rotation possible: put the new key first, leave the old one behind it
  until nothing needs it.

      TarsVault.generate_key()
      #=> "hX2...=="

  Without a key nothing is written and nothing is read: every call answers
  `{:error, :no_key}` rather than falling back to plaintext.

  The key seals the value only. Which user has a secret for which name is
  visible to anyone who can read the store, and the store is the customer's.
  Two owners, or two names, never share a key: see `path/2`.

  ## Extracting this package

  When the vault moves out into `tars_vault`, `lib/tars_vault/` and
  `test/tars_vault/` move into a project declaring `{:tars, "~> 0.1"}`, and the
  setting becomes `config :tars_vault, keys: [...]`.
  """

  @behaviour Tars.Credential

  alias Tars.Credential
  alias Tars.Scope
  alias Tars.Store
  alias TarsVault.Sealed

  @ns :vault
  # The additional data a value is sealed with: the key, under the prefix the
  # vault has always written.
  @aad_prefix "tars/vault/"
  @version 1
  @key_bytes 32
  @nonce_bytes 12

  @typedoc "Who a secret belongs to: a user, an organisation, any other term the host names, or the deployment, `nil`."
  @type owner() :: term()

  @impl Tars.Credential
  def resolve(ref, %Tars.Call{scope: %Scope{} = scope}) do
    with {:ok, owner} <- owner(ref, scope),
         {:ok, secret} <- fetch(ref, owner) do
      {:ok, Credential.secret(secret)}
    end
  end

  @doc """
  Seals `secret` and writes it down.

  Overwrites whatever was there, so re-authorizing is a `put/3`.
  """
  @spec put(Credential.ref(), owner(), String.t()) :: :ok | {:error, term()}
  def put(ref, owner, secret) when is_binary(secret) do
    with {:ok, key} <- sealing_key(),
         {:ok, path} <- path(ref, owner) do
      write(path, seal(key, path, secret))
    end
  end

  @doc "Unseals the secret written for this reference and owner."
  @spec fetch(Credential.ref(), owner()) :: {:ok, String.t()} | {:error, term()}
  def fetch(ref, owner) do
    with {:ok, keys} <- unsealing_keys(),
         {:ok, path} <- path(ref, owner),
         {:ok, %Sealed{} = sealed} <- read(path) do
      unseal(keys, path, sealed)
    end
  end

  @doc "Whether a secret is written for this reference and owner."
  @spec has?(Credential.ref(), owner()) :: boolean()
  def has?(ref, owner), do: match?({:ok, _secret}, fetch(ref, owner))

  @doc "Removes a secret. Removing one that is not there is still `:ok`."
  @spec forget(Credential.ref(), owner()) :: :ok | {:error, term()}
  def forget(ref, owner) do
    with {:ok, path} <- path(ref, owner), do: Store.delete(@ns, path)
  end

  @doc """
  The references an owner has secrets for, as `{kind, name}` pairs.

  Reads no secret and needs no key.
  """
  @spec names(:user | :org | :named, owner()) :: [Credential.ref()]
  def names(kind, owner) do
    prefix = "#{kind}/" <> segment(owner) <> "/"

    for key <- Store.keys(@ns, prefix),
        name = String.replace_prefix(key, prefix, ""),
        name != "",
        do: {kind, name}
  end

  @doc "A new key, base64-encoded, for `:keys`."
  @spec generate_key() :: String.t()
  def generate_key, do: @key_bytes |> :crypto.strong_rand_bytes() |> Base.encode64()

  @doc "Whether this deployment gave the vault a key to work with."
  @spec ready?() :: boolean()
  def ready?, do: match?({:ok, _key}, sealing_key())

  @doc "The namespace secrets are written under in `Tars.Store`."
  @spec namespace() :: Store.ns()
  def namespace, do: @ns

  @doc """
  The key a reference and owner are written under, within `namespace/0`.
  Distinct references and owners are written under distinct keys.
  """
  @spec path(Credential.ref(), owner()) :: {:ok, String.t()} | {:error, term()}
  def path({kind, name}, owner) when kind in [:user, :org, :named] and is_binary(name) do
    {:ok, "#{kind}/" <> segment(owner) <> "/" <> segment(name)}
  end

  def path(ref, _owner), do: {:error, {:unknown_reference, ref}}

  defp owner({:user, _name}, %Scope{user: nil}), do: {:error, :no_user}
  defp owner({:user, _name}, %Scope{user: user}), do: {:ok, user}
  defp owner({:org, _name}, %Scope{org: nil}), do: {:error, :no_org}
  defp owner({:org, _name}, %Scope{org: org}), do: {:ok, org}
  defp owner({:named, _name}, %Scope{}), do: {:ok, nil}
  defp owner(ref, %Scope{}), do: {:error, {:unknown_reference, ref}}

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

  # The path is authenticated along with the secret, so a sealed value moved to
  # another user's key will not unseal there.
  defp seal(key, path, secret) do
    nonce = :crypto.strong_rand_bytes(@nonce_bytes)

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(:aes_256_gcm, key, nonce, secret, @aad_prefix <> path, true)

    %Sealed{version: @version, nonce: nonce, ciphertext: ciphertext, tag: tag}
  end

  defp unseal(keys, path, %Sealed{version: @version} = sealed) do
    aad = @aad_prefix <> path

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

  defp configured_keys, do: TarsVault.Config.keys()

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
end
