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

    %{events: events, next: next} =
      scope.wardrik
      |> Wardrik.events()
      |> Wardrik.EventLog.audit(opts)

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

    mcp = Wardrik.mcp(wardrik)
    :ok = Wardrik.MCP.reconcile(mcp)
    triggers = Wardrik.triggers(wardrik)
    :ok = Wardrik.Triggers.reconcile(triggers)

    here = to_string(node())

    Changes.record_deployment(scope,
      type: "agents.reloaded",
      subject: "deployment",
      data: %{"nodes" => [here]}
    )

    {:ok, %{"reloaded" => [here], "problems" => problems}}
  end

  @doc """
  Lists the nodes, with how many agents run on each, how many of those are running, idle or
  parked, and how many sleep.
  """
  @spec nodes(Wardrik.Scope.t(), map()) :: {:ok, map()}
  def nodes(%Wardrik.Scope{wardrik: wardrik}, _input) do
    agents = Wardrik.agents(wardrik)

    placements =
      agents
      |> WardrikCore.placements()
      |> Map.values()

    counts = Enum.frequencies(placements)

    nodes =
      for name <- WardrikCore.nodes(agents),
          do: %{"name" => name, "agents" => Map.get(counts, name, 0)}

    events = Wardrik.events(wardrik)

    states =
      agents
      |> WardrikCore.running()
      |> Enum.map(fn {key, _pid} ->
        activity = Wardrik.EventLog.activity(events, key)
        Snapshot.status(activity)
      end)
      |> Enum.frequencies()

    {:ok,
     %{
       "nodes" => nodes,
       "running" => Map.get(states, "running", 0),
       "idle" => Map.get(states, "idle", 0),
       "parked" => Map.get(states, "parked", 0),
       "asleep" => Map.get(counts, nil, 0)
     }}
  end

  @doc "Moves an agent to another node."
  @spec move(Wardrik.Scope.t(), map()) :: {:ok, map()} | {:error, Error.t()}
  def move(%Wardrik.Scope{wardrik: wardrik} = scope, %{"node" => node} = input) do
    key = Running.key(input)
    id = Running.describe(key)

    agents = Wardrik.agents(wardrik)

    case WardrikCore.move(agents, key, to: node) do
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
