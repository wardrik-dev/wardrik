defmodule Wardrik.Catalog.Self do
  @moduledoc """
  The catalog's operations on an agent, offered to that agent as tools, so
  it can read and change itself as any surface could: read its snapshot and
  its definition, define itself again, send itself a message, and set and
  remove its own triggers. A tool source, named with the agent's ID:

      Wardrik.LLM.Config.new(tools: [{Wardrik.Catalog.Self, ~A"acme/watch"}])

  Each operation of `Wardrik.Catalog.agent_queries/0` and
  `Wardrik.Catalog.agent_commands/0` is a tool named `self_` and the rest of
  its name, `.` written `_`, as `self_trigger_set` for `agent.trigger.set`.
  A call acts on the agent, its conversation's agent where a conversation
  calls it, granted no further; see `Wardrik.Catalog.Tools` for how it runs.
  """

  @behaviour Wardrik.Tool

  alias Wardrik.AgentID
  alias Wardrik.AgentID.Prefix
  alias Wardrik.Catalog
  alias Wardrik.Catalog.Tools
  alias Wardrik.Catalog.Tools.Bound

  @impl Wardrik.Tool
  def tools(%AgentID{} = agent) do
    agent = AgentID.put_external_id(agent, nil)

    for bound <- Tools.agent_operations(Prefix.of(agent)),
        do:
          Tools.tool(bound,
            name: name(bound.module),
            schema: bound.module.input(),
            run: {__MODULE__, :run, [bound, agent]}
          )
  end

  @impl Wardrik.Tool
  def annotations(%AgentID{}, name),
    do: Tools.annotations(Enum.map(Catalog.agent_commands(), &name/1), name)

  defp name(module),
    do:
      "self_" <>
        (module.name() |> String.replace_prefix("agent.", "") |> String.replace(".", "_"))

  @doc false
  @spec run(Bound.t(), AgentID.t(), map(), Wardrik.Tool.Context.t()) :: Wardrik.Tool.answer()
  def run(bound, agent, input, context),
    do: Tools.run(bound, agent, input: input, context: context)
end
