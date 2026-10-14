defmodule WardrikWorkspace.Mount do
  @moduledoc """
  One tree in an agent's workspace, and where the agent sees it: its own at the
  root, and each tree it shares at `shared/<name>`.

    * `:name` - `nil` for the agent's own tree, or the name it is shared under
    * `:tree` - the tree, as the host's `Wardrik.Workspace` names it
    * `:mode` - `:write`, or `:read` for a tree the agent may only read

  Every tree is kept in the one `Wardrik.Workspace` of the host the agent
  runs on, so nothing stored with an agent names where.
  """

  @enforce_keys [:tree]
  defstruct [:name, :tree, mode: :write]

  @type t() :: %__MODULE__{
          name: String.t() | nil,
          tree: String.t(),
          mode: :write | :read
        }

  @doc "Where the mount's files are seen: `\"\"` for the agent's own, `shared/<name>/` for one it shares."
  @spec root(t()) :: String.t()
  def root(%__MODULE__{name: nil}), do: ""
  def root(%__MODULE__{name: name}), do: "shared/" <> name <> "/"
end
