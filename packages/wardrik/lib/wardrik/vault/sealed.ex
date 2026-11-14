defmodule Wardrik.Vault.Sealed do
  @moduledoc """
  A credential as the vault writes it. Only a key can unseal it.

  The store keeps it as its kind, and its nonce, ciphertext and tag in base64.
  """

  @behaviour Wardrik.Format

  @enforce_keys [:kind, :nonce, :ciphertext, :tag]
  defstruct [:kind, :nonce, :ciphertext, :tag]

  @typedoc "A sealed secret or grant."
  @type t() :: %__MODULE__{
          kind: Wardrik.Vault.kind(),
          nonce: binary(),
          ciphertext: binary(),
          tag: binary()
        }

  @key_bytes 32
  @nonce_bytes 12

  @impl Wardrik.Format
  def version, do: 1

  @impl Wardrik.Format
  def dump(%__MODULE__{} = sealed) do
    %{
      "kind" => Atom.to_string(sealed.kind),
      "nonce" => Base.encode64(sealed.nonce),
      "ciphertext" => Base.encode64(sealed.ciphertext),
      "tag" => Base.encode64(sealed.tag)
    }
  end

  @impl Wardrik.Format
  def load(1, %{"kind" => kind, "nonce" => nonce, "ciphertext" => ciphertext, "tag" => tag}) do
    kinds = Map.new(Wardrik.Vault.kinds(), &{Atom.to_string(&1), &1})

    with {:ok, kind} <- Map.fetch(kinds, kind),
         {:ok, nonce} <- Base.decode64(nonce),
         {:ok, ciphertext} <- Base.decode64(ciphertext),
         {:ok, tag} <- Base.decode64(tag) do
      {:ok, %__MODULE__{kind: kind, nonce: nonce, ciphertext: ciphertext, tag: tag}}
    else
      :error -> {:error, "a sealed value of kind #{kind} isn't one this release reads"}
    end
  end

  @doc """
  Seals `value` with `:key`. Binds it to `:path` and `:kind`, so it can't be moved or relabelled.

      Wardrik.Vault.Sealed.seal("ghp_...", key: key, path: "user%3Ajon/github", kind: :secret)
  """
  @spec seal(binary(), key: binary(), path: String.t(), kind: Wardrik.Vault.kind()) :: t()
  def seal(value, args) do
    key = Keyword.fetch!(args, :key)
    path = Keyword.fetch!(args, :path)
    kind = Keyword.fetch!(args, :kind)
    nonce = :crypto.strong_rand_bytes(@nonce_bytes)

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(:aes_256_gcm, key, nonce, value, aad(path, kind), true)

    %__MODULE__{kind: kind, nonce: nonce, ciphertext: ciphertext, tag: tag}
  end

  @doc """
  Unseals with the first of `keys` that opens it.

  Returns `{:error, :undecipherable}` if none does.
  """
  @spec unseal(t(), [binary()], String.t()) :: {:ok, binary()} | {:error, :undecipherable}
  def unseal(%__MODULE__{} = sealed, keys, path) do
    aad = aad(path, sealed.kind)

    keys
    |> Enum.find_value(fn key -> opened(key, sealed, aad) end)
    |> unsealed()
  end

  @doc "Decodes base64 keys. Drops any that don't hold #{@key_bytes} bytes."
  @spec decode_keys([String.t()]) :: [binary()]
  def decode_keys(keys), do: Enum.flat_map(keys, &decode_key/1)

  @doc "Returns a new key, base64-encoded."
  @spec generate_key() :: String.t()
  def generate_key do
    @key_bytes
    |> :crypto.strong_rand_bytes()
    |> Base.encode64()
  end

  defp opened(key, sealed, aad) do
    case :crypto.crypto_one_time_aead(
           :aes_256_gcm,
           key,
           sealed.nonce,
           sealed.ciphertext,
           aad,
           sealed.tag,
           false
         ) do
      :error -> nil
      value -> value
    end
  end

  defp unsealed(nil), do: {:error, :undecipherable}
  defp unsealed(value), do: {:ok, value}

  defp aad(path, kind), do: "wardrik_vault/#{kind}/" <> path

  defp decode_key(key) when is_binary(key) do
    case Base.decode64(key) do
      {:ok, <<decoded::binary-size(@key_bytes)>>} -> [decoded]
      _other -> []
    end
  end

  defp decode_key(_key), do: []

  defimpl Inspect do
    @impl true
    def inspect(%{kind: kind, ciphertext: ciphertext}, _opts),
      do: "#Wardrik.Vault.Sealed<#{kind}, #{byte_size(ciphertext)} bytes>"
  end
end
