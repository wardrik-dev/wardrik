defmodule Wardrik.LLM.Model do
  @moduledoc """
  A model as its client knows it: the spec it was asked for, how many tokens
  it reads at once, and the secret its provider's key is read from.

  `window` is `nil` where the client does not know it. `key` names the
  secret, such as `"ANTHROPIC_API_KEY"`, a call to the model needs a key
  from, or is `nil` where the client already holds one, in its config or the
  environment; see `Wardrik.LLM.Key`.
  """

  @enforce_keys [:spec]
  defstruct [:spec, :window, :key]

  @type t() :: %__MODULE__{spec: term(), window: pos_integer() | nil, key: String.t() | nil}
end
