defmodule Wardrik.Grants.None do
  @moduledoc """
  The `Wardrik.Grants` of a host that grants nobody anything: every
  principal holds no grant, so nobody known by a principal alone reaches
  any agent. A `Wardrik.Host` that names no `:grants` has it.
  """

  @behaviour Wardrik.Grants

  @impl Wardrik.Grants
  def grants(_principal), do: []
end
