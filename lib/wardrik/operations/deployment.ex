defmodule Wardrik.Operations.Deployment do
  @moduledoc false

  alias Wardrik.Error
  alias Wardrik.Operations.Changes
  alias Wardrik.Operations.Running
  alias Wardrik.Operations.Snapshot

  @doc "Returns a page of the deployment's audit."
  @spec audit(Wardrik.Scope.t(), map()) :: {:ok, map()}
  def audit(scope, input) do
    opts = [after: input["starting_after"] || 0, limit: input["limit"] || 100]
    %{events: events, next: next} = WardrikEvents.audit(Wardrik.events(scope.wardrik), opts)
    {:ok, %{"events" => events, "next" => next}}
  end

  @doc """
  Reloads declarations, updates running agents to their definitions, and reconciles servers and
  triggers. Returns the node, and a line for each problem.
  """
  @spec reload(Wardrik.Scope.t(), map()) :: {:ok, map()}
  def reload(%Wardrik.Scope{wardrik: wardrik} = scope, input) do
    problems = Wardrik.Declarations.reload(wardrik)
    named = input["agents"]

    _failed = Wardrik.Resolution.refresh(wardrik, named || :all)

    :ok = WardrikMCP.reconcile(Wardrik.mcp(wardrik))
    :ok = WardrikTriggers.reconcile(Wardrik.triggers(wardrik))

    here = to_string(node())

    Changes.record_deployment(scope,
      type: "agents.reloaded",
      subject: "deployment",
      data: %{"nodes" => [here]}
    )

    {:ok, %{"reloaded" => [here], "problems" => problems}}
  end

  @doc "Lists the nodes, with how many agents run on each and how many sleep."
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
  def move(%Wardrik.Scope{wardrik: wardrik} = scope, %{"node" => node} = input) do
    key = Running.key(input)
    id = Running.describe(key)

    case WardrikCore.move(Wardrik.agents(wardrik), key, to: node) do
      {:ok, _pid} ->
        Changes.record(scope, type: "agent.moved", agent: key, data: %{"node" => node})
        {:ok, %{"agent" => Snapshot.summary(wardrik, key)}}

      {:error, :not_found} ->
        {:error, Error.new(:not_found, "There's no agent #{id}.")}

      {:error, :no_such_node} ->
        {:error, Error.new(:invalid_request, "There's no node #{node} in the cluster.")}

      {:error, reason} ->
        {:error, Error.new(:unavailable, "#{id} didn't move: #{inspect(reason)}")}
    end
  end
end
