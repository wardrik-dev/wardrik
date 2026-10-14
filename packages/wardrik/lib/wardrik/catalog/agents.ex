defmodule Wardrik.Catalog.Agents do
  @moduledoc """
  The catalog's operations on the agents of an agent's owner, offered to that
  agent as tools, so it can delegate: list the agents it can reach, read
  one's snapshot or definition, send one a message and hear its answer back,
  and define a worker or change one's triggers. A tool source, named with
  the agent's ID:

      Wardrik.LLM.Config.new(tools: [{Wardrik.Catalog.Agents, ~A"acme/front"}])

  Each operation of `Wardrik.Catalog.agent_queries/0` and
  `Wardrik.Catalog.agent_commands/0` is a tool named for it, `.` written `_`,
  as `agent_ask` for `agent.ask`, taking its input and the `agent` it acts
  on, by name within the org: `reconciler`, or `@jon/reconciler` for one
  that works for a user. Each of `Wardrik.Catalog.fleet_queries/0`, as
  `agents_list`, acts on every agent of the owner.

  A call reaches the agents of the calling agent's owner and no other: its
  org's own, or those of the user it works for. One named in another org,
  or working for someone else, is one that does not exist, to it. See
  `Wardrik.Catalog.Tools` for how a call runs, what an agent it defines is
  held to, and how an answer it is sent comes back.
  """

  @behaviour Wardrik.Tool

  alias Wardrik.AgentID
  alias Wardrik.AgentID.Prefix
  alias Wardrik.Catalog
  alias Wardrik.Catalog.Tools
  alias Wardrik.Catalog.Tools.Offering
  alias Wardrik.Error
  alias Wardrik.Resource

  @agent %{
    "type" => "string",
    "description" =>
      "The agent, by its name within the org, as reconciler, or @user/name for one that " <>
        "works for a user."
  }

  @impl Wardrik.Tool
  def tools(%AgentID{} = agent) do
    reach = Prefix.owner(agent)

    agents =
      for offering <- Tools.agent_operations(reach),
          do:
            Tools.tool(offering,
              name: name(offering.module),
              schema: aimed(offering.module.input()),
              run: {__MODULE__, :run, [offering]}
            )

    fleet =
      for offering <- Tools.fleet_operations(reach),
          do:
            Tools.tool(offering,
              name: name(offering.module),
              schema: offering.module.input(),
              run: {__MODULE__, :run_all, [offering]}
            )

    agents ++ fleet
  end

  @impl Wardrik.Tool
  def annotations(%AgentID{}, name),
    do: Tools.annotations(Enum.map(Catalog.agent_commands(), &name/1), name)

  defp name(module), do: String.replace(module.name(), ".", "_")

  defp aimed(schema) do
    schema
    |> Map.update!("properties", &Map.put(&1, "agent", @agent))
    |> Map.update("required", ["agent"], &["agent" | &1])
    |> Map.update("examples", [], fn examples ->
      Enum.map(examples, &Map.put(&1, "agent", "reconciler"))
    end)
  end

  @doc false
  @spec run(Offering.t(), map(), Wardrik.Tool.Context.t()) :: Wardrik.Tool.answer()
  def run(%Offering{reach: reach} = offering, %{"agent" => name} = input, context)
      when is_binary(name) do
    case AgentID.expand(name, Prefix.org(reach)) do
      {:ok, agent} ->
        Tools.run(offering, agent, input: Map.delete(input, "agent"), context: context)

      {:error, message} ->
        {:error, Resource.error(Error.new(:invalid, message))}
    end
  end

  def run(_offering, _input, _context),
    do: {:error, Resource.error(Error.new(:invalid, "Name the agent the call acts on, as agent"))}

  @doc false
  @spec run_all(Offering.t(), map(), Wardrik.Tool.Context.t()) :: Wardrik.Tool.answer()
  def run_all(%Offering{reach: reach} = offering, input, context),
    do: Tools.run(offering, reach, input: input, context: context)
end
