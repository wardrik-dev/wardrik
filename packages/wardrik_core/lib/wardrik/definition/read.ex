defmodule Wardrik.Definition.Read do
  @moduledoc """
  A definition as `Wardrik.Definition.get/2` reads it back: its `fields`, as
  they were sent, and the tools it names that offer nothing yet, such as an
  MCP server its owner has not added, as `missing`. Each comes in as soon as
  what it names is there, without the definition being put again.
  """

  @enforce_keys [:fields, :missing]
  defstruct [:fields, :missing]

  @type t() :: %__MODULE__{fields: map(), missing: [String.t()]}
end
