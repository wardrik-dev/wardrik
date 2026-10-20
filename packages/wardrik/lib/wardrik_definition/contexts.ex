defprotocol WardrikDefinition.Contexts do
  @moduledoc """
  The `WardrikDefinition.Context` each agent's definition is read under,
  chosen by the owner of the agent: its org, or a user in it, as
  `Wardrik.Resource` names a namespace.

  A host that reads every definition alike passes one
  `WardrikDefinition.Context`, which answers itself. One that holds each
  org's agents to a policy of its own, or changes it while it runs, passes a
  struct of its own that builds the context for the owner it is asked
  about, as one holding each org to the allowance it pays for:

      defimpl WardrikDefinition.Contexts, for: MyApp.Contexts do
        def context(%MyApp.Contexts{base: base}, owner),
          do: %{base | held: base.held ++ [MyApp.Billing.allowance(Wardrik.Resource.org(owner))]}

        def reload(_contexts, _opts), do: []
      end

  `MyApp.Billing.allowance/1` answers a `WardrikPolicy` with a budget, so
  every agent of the org spends from it together (see `held` in
  `WardrikDefinition.Context`).

  A definition is read under the context as it is put, and keeps what it
  read until it is read again, as `Wardrik.deployment_reload/2` reads
  them; the policies it names are found in the context each time its agent
  starts.
  """

  @doc "The context the definitions of the agents `owner` owns are read under."
  @spec context(t(), Wardrik.Resource.t()) :: WardrikDefinition.Context.t()
  def context(contexts, owner)

  @doc """
  Reads again what the contexts are read from, on this node, with the
  `:host` asking, as `Wardrik.deployment_reload/2` asks before the
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
