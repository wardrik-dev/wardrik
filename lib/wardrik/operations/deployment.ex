defmodule Wardrik.Operations.Deployment do
  @moduledoc "Operations on the deployment: the audit, nodes, moving agents and reloading."

  alias Wardrik.Definitions
  alias Wardrik.Error
  alias Wardrik.Operations.Changes
  alias Wardrik.Operations.Running
  alias Wardrik.Operations.Snapshot
  alias Wardrik.Resource
  alias WardrikEvents.Pattern

  @doc "Returns a page of the deployment's audit."
  @spec audit(Wardrik.Scope.t(), map()) :: {:ok, map()}
  def audit(scope, input) do
    opts = [after: input["starting_after"] || 0, limit: input["limit"] || 100]
    %{events: events, next: next} = WardrikEvents.audit(Wardrik.events(scope.wardrik), opts)
    {:ok, %{"events" => events, "next" => next}}
  end

  @doc """
  Reloads the deployment:

    1. Reloads the declarations. See `Wardrik.Declarations`.
    2. Updates running agents to their current definitions. Only those `"resources"` covers, if
       given.
    3. Reconciles MCP servers and triggers.

  Returns the node reloaded, and a line for each declaration problem.
  """
  @spec reload(Wardrik.Scope.t(), map()) :: {:ok, map()}
  def reload(%Wardrik.Scope{wardrik: wardrik} = scope, input) do
    problems = Wardrik.Declarations.reload(wardrik)
    covered = covered(input["resources"])

    for id <- Definitions.ids(wardrik), covered.(id), Running.whereis(wardrik, id) != nil do
      with {:ok, definition} <- Definitions.fetch(wardrik, id),
           {:ok, opts} <- Wardrik.Resolution.resolve(wardrik, id, definition),
           do: Running.bring(wardrik, opts)
    end

    :ok = WardrikMCP.reconcile(Wardrik.mcp(wardrik))
    :ok = WardrikTriggers.reconcile(Wardrik.triggers(wardrik))

    here = to_string(node())
    Changes.record_deployment(scope, "agents.reloaded", "deployment", %{"nodes" => [here]})
    {:ok, %{"reloaded" => [here], "problems" => problems}}
  end

  defp covered(nil), do: fn _id -> true end

  defp covered(patterns) do
    fn id ->
      {:ok, resource} = Resource.agent(id)
      Enum.any?(patterns, &Pattern.covers?(&1, resource))
    end
  end

  @doc "Lists the deployment's nodes with how many agents run on each, and how many are asleep."
  @spec nodes(Wardrik.Scope.t(), map()) :: {:ok, map()}
  def nodes(%Wardrik.Scope{wardrik: wardrik}, _input) do
    agents = Wardrik.agents(wardrik)
    placements = Map.values(WardrikCore.placements(agents))
    counts = Enum.frequencies(placements)

    nodes =
      for name <- WardrikCore.nodes(agents),
          do: %{"name" => name, "agents" => Map.get(counts, name, 0)}

    {:ok, %{"nodes" => nodes, "asleep" => Map.get(counts, nil, 0)}}
  end

  @doc "Moves an agent to another node."
  @spec move(Wardrik.Scope.t(), map()) :: {:ok, map()} | {:error, Error.t()}
  def move(%Wardrik.Scope{wardrik: wardrik} = scope, %{"agent" => id, "node" => node}) do
    case WardrikCore.move(Wardrik.agents(wardrik), id, node) do
      {:ok, _pid} ->
        Changes.record(scope, "agent.moved", id, %{"node" => node})
        {:ok, %{"agent" => Snapshot.summary(wardrik, id)}}

      {:error, :not_found} ->
        {:error, Error.new(:not_found, "There's no agent #{id}.")}

      {:error, :no_such_node} ->
        {:error, Error.new(:invalid_request, "There's no node #{node} in the cluster.")}

      {:error, reason} ->
        {:error, Error.new(:unavailable, "#{id} didn't move: #{inspect(reason)}")}
    end
  end
end
