defmodule WardrikMCP.Auth.Secret do
  @moduledoc """
  A server reached with a key the owner keeps in the vault, under `:name`,
  sent in `:header` after `:scheme` with every call. Each call resolves it
  for the agent's owner, so an owner who has not put it in the vault yet
  is asked to.
  """

  @enforce_keys [:name, :header, :scheme]
  defstruct [:name, :header, :scheme]

  @type t() :: %__MODULE__{name: String.t(), header: String.t(), scheme: String.t()}

  defimpl WardrikMCP.Auth do
    def options(%{name: name, header: header, scheme: scheme}, _key),
      do: [credential: name, credential_header: header, credential_scheme: scheme]

    def name(_secret), do: "secret"
    def provider(_secret, _key, _url), do: :none
  end
end
