defmodule Wardrik.Triggers.None do
  @moduledoc """
  The `Wardrik.Triggers` of a host that takes no requests for triggers:
  `deliver/3` is `:unsupported`. A `Wardrik.Host` that names no `:triggers`
  has it.
  """

  @behaviour Wardrik.Triggers

  @impl Wardrik.Triggers
  def deliver(_id, _name, _request), do: :unsupported
end
