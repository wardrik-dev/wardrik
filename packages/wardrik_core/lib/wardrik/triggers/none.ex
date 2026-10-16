defmodule Wardrik.Triggers.None do
  @moduledoc """
  The `Wardrik.Triggers` of a host that takes no requests for triggers:
  `deliver/4` is `:unsupported`. A `Wardrik.Host` that names no `:triggers`
  has it.
  """

  defstruct []

  @type t() :: %__MODULE__{}
end

defimpl Wardrik.Triggers, for: Wardrik.Triggers.None do
  def deliver(_triggers, _id, _name, _opts), do: :unsupported
end
