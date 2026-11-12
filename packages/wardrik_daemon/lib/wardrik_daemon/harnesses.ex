defmodule WardrikDaemon.Harnesses do
  @moduledoc """
  Gives an agent the coding agent `config.yaml`'s `harnesses` names, as a tool of the same name.

      tools: [claude]

    * The agent's org must use the harness. See `WardrikDaemon.Config.Orgs`.
    * Each permission request is a tool call named by its ACP kind, as `claude/execute`. See
      `WardrikACP`.
  """

  @behaviour WardrikCore.Capability

  alias WardrikDaemon.Config.Orgs
  alias WardrikDaemon.Owners

  @doc "Returns each harness by name, as Wardrik's `:capabilities` option takes them."
  @spec capabilities(atom(), Wardrik.Store.t(), WardrikDaemon.Config.t()) ::
          [{String.t(), {module(), map()}}]
  def capabilities(wardrik, store, config) do
    for {name, _harness} <- config.harnesses,
        do: {name, {__MODULE__, %{acp: acp(wardrik), store: store, config: config, name: name}}}
  end

  @doc "Returns the name `WardrikACP` runs under for `wardrik`, as `MyWardrik.ACP`."
  @spec acp(atom()) :: atom()
  def acp(wardrik), do: Module.concat(wardrik, ACP)

  @impl WardrikCore.Capability
  def tools(context, %{acp: acp, store: store, config: config, name: name}) do
    org = Owners.org_of(store, {:agent, context.agent_id})

    if Orgs.serves?(config, kind: :harnesses, name: name, org: org),
      do: WardrikACP.tools(context, name: acp, harnesses: name),
      else: []
  end
end
