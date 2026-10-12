defmodule Wardrik.Change do
  @moduledoc """
  A change a `Wardrik.Command` planned, and has not made: the request it
  answers, and what `Wardrik.Audit` records once it is made.

  A change is data, so it can be shown before it is made, asked about, or
  kept until a person agrees to it, and made later with
  `Wardrik.Command.make/2`.
  """

  @enforce_keys [:request]
  defstruct [:request, audit: []]

  @type t() :: %__MODULE__{request: struct(), audit: [Wardrik.Audit.action()]}

  @doc "A change that makes `request`, recorded in the audit as `audit`, none or more."
  @spec new(struct(), [Wardrik.Audit.action()]) :: t()
  def new(request, audit \\ []) when is_struct(request) and is_list(audit),
    do: %__MODULE__{request: request, audit: audit}
end
