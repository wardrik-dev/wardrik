defmodule Wardrik.Issuer.None do
  @moduledoc """
  The `Wardrik.Issuer` of a host that allows nobody anything: every token
  it issues has an empty scope, so whoever is known by a principal alone
  reaches no agent. A `Wardrik.Host` that names no `:issuer` has it.
  """

  defstruct []

  @type t() :: %__MODULE__{}
end

defimpl Wardrik.Issuer, for: Wardrik.Issuer.None do
  def issue(_none, principal, _opts), do: %Wardrik.Token{principal: principal}
end
