defprotocol WardrikDefinition.Source do
  @moduledoc """
  A tool source a `Wardrik.Host` holds by the name a definition names it
  with, `name/*`, as a package registers it among the host's `:sources`:
  what it gives the agent of each definition that names it, read as the
  agent's spec is built.

  A module is handed the agent's ID, as `Wardrik.Catalog.Self` is, and
  gives `{module, id}`. A value of a package's own gives what it gives, or
  refuses the agent and says why, as an MCP server a host configures for
  some orgs refuses the agents of the others.
  """

  @doc "The spec of what `source` gives the agent `id`, or why it gives it nothing."
  @spec spec(t(), Wardrik.AgentID.t()) :: {:ok, Wardrik.Tool.spec()} | {:error, String.t()}
  def spec(source, id)
end

defimpl WardrikDefinition.Source, for: Atom do
  def spec(module, id), do: {:ok, {module, id}}
end
