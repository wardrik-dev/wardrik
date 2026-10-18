defmodule Wardrik.Catalog.Self do
  @moduledoc """
  The catalog's entries on an agent, offered to that agent as tools, so it
  can read and change itself as any surface could: read its snapshot and
  its definition, define itself again, send itself a message, and set and
  remove its own triggers. A tool source, named with the agent's ID:

      Wardrik.LLM.Config.new(tools: [{Wardrik.Catalog.Self, ~A"acme/watch"}])

  Each entry of `Wardrik.Catalog.agent/0` is a tool named `self_` and the
  rest of its name, `.` written `_`, as `self_trigger_set` for
  `agent.trigger.set`. A call acts on the agent, its conversation's agent
  where a conversation calls it, and reaches no further; see
  `Wardrik.Catalog.Tools` for how it runs.
  """

  @behaviour Wardrik.Tool

  alias Wardrik.AgentID
  alias Wardrik.AgentID.Prefix
  alias Wardrik.Catalog
  alias Wardrik.Catalog.Entry
  alias Wardrik.Catalog.Tools

  @impl Wardrik.Tool
  def tools(%AgentID{} = agent) do
    agent = AgentID.put_external_id(agent, nil)

    for entry <- Catalog.agent(),
        do:
          Tools.tool(entry,
            name: name(entry),
            schema: Entry.input(entry),
            run: {__MODULE__, :run, [entry, agent]}
          )
  end

  @impl Wardrik.Tool
  def annotations(%AgentID{}, name),
    do: Tools.annotations(Enum.find(Catalog.agent(), &(name(&1) == name)))

  defp name(%Entry{name: "agent." <> rest}), do: "self_" <> String.replace(rest, ".", "_")

  @doc false
  @spec run(Entry.t(), AgentID.t(), map(), Wardrik.Tool.Context.t()) :: Wardrik.Tool.answer()
  def run(entry, agent, input, context),
    do: Tools.run(entry, agent, reach: Prefix.of(agent), input: input, context: context)
end
