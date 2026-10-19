defmodule Wardrik.Catalog.Agents do
  @moduledoc """
  The catalog's entries on the agents of an agent's owner, offered to that
  agent as tools, so it can delegate: list the agents it can reach, read
  one's snapshot or definition, send one a message and hear its answer back,
  and define a worker or change one's triggers. A tool source, named with
  the agent's ID:

      Wardrik.LLM.Config.new(tools: [{Wardrik.Catalog.Agents, ~A"acme/front"}])

  Each entry of `Wardrik.Catalog.agent/0` is a tool named for it, `.`
  written `_`, as `agent_ask` for `agent.ask`, taking its input and the
  `agent` it acts on, by name within the org: `reconciler`, or
  `@jon/reconciler` for one that works for a user. Each of
  `Wardrik.Catalog.fleet/0`, as `agents_list`, acts on every agent of the
  owner.

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
  alias Wardrik.Catalog.Entry
  alias Wardrik.Catalog.Tools
  alias Wardrik.Error
  alias Wardrik.JSON

  @agent %{
    "type" => "string",
    "description" =>
      "The agent, by its name within the org, as reconciler, or @user/name for one that " <>
        "works for a user."
  }

  @impl Wardrik.Tool
  def tools(%AgentID{} = agent) do
    reach = Prefix.owner(agent)

    # An entry on one agent takes the agent it acts on; one on them all takes none.
    one =
      for on_one <- Catalog.agent(),
          do:
            Tools.tool(on_one,
              name: name(on_one),
              schema: aimed(Entry.input(on_one)),
              run: {__MODULE__, :run, [on_one, reach]}
            )

    all =
      for on_all <- Catalog.fleet(),
          do:
            Tools.tool(on_all,
              name: name(on_all),
              schema: Entry.input(on_all),
              run: {__MODULE__, :run_all, [on_all, reach]}
            )

    one ++ all
  end

  @impl Wardrik.Tool
  def annotations(%AgentID{}, name),
    do: Tools.annotations(Enum.find(Catalog.agent(), &(name(&1) == name)))

  defp name(%Entry{name: name}), do: String.replace(name, ".", "_")

  defp aimed(schema) do
    schema
    |> Map.update!("properties", &Map.put(&1, "agent", @agent))
    |> Map.update("required", ["agent"], &["agent" | &1])
    |> Map.update("examples", [], fn examples ->
      Enum.map(examples, &Map.put(&1, "agent", "reconciler"))
    end)
  end

  @doc false
  @spec run(Entry.t(), Prefix.t(), map(), Wardrik.Tool.Context.t()) :: Wardrik.Tool.answer()
  def run(entry, reach, %{"agent" => name} = input, context) when is_binary(name) do
    case AgentID.expand(name, Prefix.org(reach)) do
      {:ok, agent} ->
        Tools.run(entry, agent, reach: reach, input: Map.delete(input, "agent"), context: context)

      {:error, message} ->
        {:error, JSON.error(Error.new(:invalid, message))}
    end
  end

  def run(_entry, _reach, _input, _context),
    do: {:error, JSON.error(Error.new(:invalid, "Name the agent the call acts on, as agent"))}

  @doc false
  @spec run_all(Entry.t(), Prefix.t(), map(), Wardrik.Tool.Context.t()) :: Wardrik.Tool.answer()
  def run_all(entry, reach, input, context),
    do: Tools.run(entry, reach, reach: reach, input: input, context: context)
end
