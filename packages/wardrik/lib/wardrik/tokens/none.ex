defmodule Wardrik.Tokens.None do
  @moduledoc """
  The `Wardrik.Tokens` of a host that makes none: each callback is
  `:unsupported`. A `Wardrik.Host` that names no `:tokens` has it.
  """

  @behaviour Wardrik.Tokens

  @impl Wardrik.Tokens
  def create(_name, _grant, _for), do: :unsupported

  @impl Wardrik.Tokens
  def list, do: :unsupported

  @impl Wardrik.Tokens
  def revoke(_id), do: :unsupported
end
