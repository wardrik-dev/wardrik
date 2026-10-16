defmodule Wardrik.Credentials.None do
  @moduledoc """
  The `Wardrik.Credentials` of a host that holds no secrets: a tool's
  credential resolves to `{:error, :no_resolver}`, and a provider's key is
  read from the environment alone. A `Wardrik.Host` that names no
  `:credentials` has it.
  """

  defstruct []

  @type t() :: %__MODULE__{}
end

defimpl Wardrik.Credentials, for: Wardrik.Credentials.None do
  def resolve(_credentials, _ref, _call), do: {:error, :no_resolver}
  def refused(_credentials, _ref, _call), do: :ok
  def key(_credentials, _name), do: :error
end
