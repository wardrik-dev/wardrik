defmodule Wardrik.Specs.None do
  @moduledoc """
  The `Wardrik.Specs` of a host that defines no agents: every agent starts
  and wakes as it was stored, and none is listed that has not started. A
  `Wardrik.Host` that names no `:definitions` has it.
  """

  defstruct []

  @type t() :: %__MODULE__{}
end

defimpl Wardrik.Specs, for: Wardrik.Specs.None do
  def current(_none, _id, _opts), do: :none
  def defined(_none, _pattern), do: []
end
