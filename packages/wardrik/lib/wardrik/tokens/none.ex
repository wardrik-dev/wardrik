defmodule Wardrik.Tokens.None do
  @moduledoc """
  The `Wardrik.Tokens` of a host that makes none: each function is
  `:unsupported`. A `Wardrik.Host` that names no `:tokens` has it.
  """

  defstruct []

  @type t() :: %__MODULE__{}

  @doc "The error each operation answers where the host makes no tokens."
  @spec unsupported() :: Wardrik.Error.t()
  def unsupported, do: Wardrik.Error.new(:unsupported, "This server makes no tokens.")
end

defimpl Wardrik.Tokens, for: Wardrik.Tokens.None do
  def create(_tokens, _name, _opts), do: :unsupported
  def list(_tokens), do: :unsupported
  def revoke(_tokens, _id), do: :unsupported
end
