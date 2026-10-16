defmodule Wardrik.Grants.None do
  @moduledoc """
  The `Wardrik.Grants` of a host that grants nobody anything: every
  principal holds no grant, so nobody known by a principal alone reaches
  any agent. A `Wardrik.Host` that names no `:grants` has it.
  """

  defstruct []

  @type t() :: %__MODULE__{}
end

defimpl Wardrik.Grants, for: Wardrik.Grants.None do
  def grants(_grants, _principal), do: []
end
