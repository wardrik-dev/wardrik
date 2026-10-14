defmodule WardrikWorkspace.Test.Workspace do
  @moduledoc false
  # The workspace the suite's files are kept in, and a host keeping them there.

  def workspace, do: %WardrikWorkspace.Backend.Store{store: Wardrik.Test.store()}

  def host, do: Wardrik.Test.host(workspace: workspace())
end
