defmodule WardrikWorkspace.Test.Workspace do
  @moduledoc false
  # The workspace the suite's files are kept in, and a host keeping them
  # there, with the other seams `opts` name.

  def workspace, do: %WardrikWorkspace.Backend.Store{store: Wardrik.Test.store()}

  def host(opts \\ []), do: Wardrik.Test.host([workspace: workspace()] ++ opts)
end
