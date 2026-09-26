defmodule WardrikVault.Sealed do
  @moduledoc """
  One secret as it is written down: a version, the nonce it was sealed with,
  the ciphertext, and the tag that authenticates both.

  Nothing here is readable without the key, and `inspect/1` shows only the
  version and the length.
  """

  @enforce_keys [:version, :nonce, :ciphertext, :tag]
  defstruct [:version, :nonce, :ciphertext, :tag]

  @typedoc "A sealed secret."
  @type t() :: %__MODULE__{
          version: pos_integer(),
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
