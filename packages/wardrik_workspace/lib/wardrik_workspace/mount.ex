defmodule WardrikWorkspace.Mount do
  @moduledoc """
  A tree an agent sees.

    * `:tree` - the tree's name in the store.
    * `:name` - where it's shown, as `shared/<name>/`. `nil` for the agent's own tree.
    * `:mode` - `:write`, or `:read` for read only. `:write` unless set.
  """

  @enforce_keys [:tree]
  defstruct [:name, :tree, mode: :write]

  @type t() :: %__MODULE__{name: String.t() | nil, tree: String.t(), mode: :read | :write}
end
