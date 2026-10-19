defmodule Wardrik.Runtime.Context do
  @moduledoc """
  What a definition resolved for `Wardrik.Runtime.read/3` to read its fields
  with: the agent's `instructions`, and the `tools` it names, as
  `t:Wardrik.Tool.spec/0` values.
  """

  defstruct instructions: nil, tools: []

  @type t() :: %__MODULE__{instructions: String.t() | nil, tools: [Wardrik.Tool.spec()]}
end
