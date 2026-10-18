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
      end

  An agent built from a context keeps the spec it was given until it is
  built again, as `Wardrik.Operations.Reload` does for every agent awake, and
  as an agent asleep is when it wakes.
  """

  @doc "The context the definition of the agent `owner` is read under."
  @spec context(t(), Wardrik.AgentID.t()) :: WardrikDefinition.Context.t()
  def context(contexts, owner)
end

defimpl WardrikDefinition.Contexts, for: WardrikDefinition.Context do
  def context(context, _owner), do: context
end
