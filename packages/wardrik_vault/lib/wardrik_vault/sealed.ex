defmodule WardrikVault.Sealed do
  @moduledoc """
  One credential as it is written down: a version, whether it is a secret or
  a grant, the nonce it was sealed with, the ciphertext, and the tag that
  authenticates them.

  Nothing here is readable without the key, and `inspect/1` shows only the
  version and the length.
  """

  @enforce_keys [:version, :nonce, :ciphertext, :tag]
  defstruct [:version, :nonce, :ciphertext, :tag, kind: :secret]

  @typedoc "A sealed secret."
  @type t() :: %__MODULE__{
          version: pos_integer(),
          kind: :secret | :grant,
          nonce: binary(),
          ciphertext: binary(),
          tag: binary()
        }

  defimpl Inspect do
    def inspect(%WardrikVault.Sealed{version: version, ciphertext: ciphertext}, _opts) do
      Inspect.Algebra.concat([
        "#WardrikVault.Sealed<v",
        to_string(version),
        ", ",
        to_string(byte_size(ciphertext)),
        " bytes, sealed>"
      ])
    end
  end
end
