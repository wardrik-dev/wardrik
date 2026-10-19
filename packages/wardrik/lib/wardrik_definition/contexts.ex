defprotocol WardrikDefinition.Contexts do
  @moduledoc """
  The `WardrikDefinition.Context` each agent's definition is read under,
  chosen by the agent that owns it.

  A host that reads every definition alike passes one
  `WardrikDefinition.Context`, which answers itself. One that holds an org's
  agents to its own policies, tools or ceilings, or changes them while it
  runs, passes a struct of its own that builds the context for the owner it
  is asked about:

      defimpl WardrikDefinition.Contexts, for: MyApp.Contexts do
        def context(%MyApp.Contexts{base: base}, owner),
          do: %{base | policies: MyApp.Policies.for_org(owner.org)}

        def reload(_contexts, _opts), do: []
      end

  A definition is read under the context as it is put, and keeps what it
  read until it is read again, as `Wardrik.deployment_reload/1` reads every
  one; the policies it names are found in the context each time its agent
  starts.
  """

  @doc "The context the definition of the agent `owner` is read under."
  @spec context(t(), Wardrik.AgentID.t()) :: WardrikDefinition.Context.t()
  def context(contexts, owner)

  @doc """
  Reads again what the contexts are read from, on this node, with the
  `:host` asking, as `Wardrik.deployment_reload/1` asks before the
  definitions are read again, and answers the files that declare agents:
  each with the definition it reads into, under the context as it is now,
  or why it does not read. A host that declares agents in no files answers
  none.
  """
  @spec reload(t(), host: Wardrik.Host.t()) ::
          [{Path.t(), {:ok, Wardrik.Definition.t()} | {:error, String.t()}}]
  def reload(contexts, opts)
end

defimpl WardrikDefinition.Contexts, for: WardrikDefinition.Context do
  def context(context, _owner), do: context
  def reload(_context, _opts), do: []
end
