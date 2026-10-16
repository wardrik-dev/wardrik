defmodule Wardrik.Workspace.None do
  @moduledoc """
  The `Wardrik.Workspace` of a host that keeps no files: each function is
  `{:error, :unsupported}`. A `Wardrik.Host` that names no `:workspace` has
  it.
  """

  defstruct []

  @type t() :: %__MODULE__{}
end

defimpl Wardrik.Workspace, for: Wardrik.Workspace.None do
  def read(_workspace, _tree, _path), do: {:error, :unsupported}
  def write(_workspace, _tree, _path, _opts), do: {:error, :unsupported}
  def delete(_workspace, _tree, _path, _opts), do: {:error, :unsupported}
  def list(_workspace, _tree, _prefix), do: {:error, :unsupported}
  def paths(_workspace, _tree, _prefix), do: {:error, :unsupported}
end
