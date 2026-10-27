defmodule Wardrik.Operations.Deployment do
  @moduledoc "The operations on the deployment itself: its audit, its nodes, and reading definitions again."

  alias Wardrik.Definition
  alias Wardrik.Definitions
  alias Wardrik.Error
  alias Wardrik.Operations.Changes
  alias Wardrik.Operations.Running
  alias Wardrik.Operations.Snapshot

  @doc "Reads a page of what people changed across the deployment."
  @spec audit(Wardrik.Scope.t(), map()) :: {:ok, map()}
  def audit(scope, input) do
    opts = [after: input["starting_after"] || 0, limit: input["limit"] || 100]
    %{events: events, next: next} = WardrikEvents.audit(Wardrik.events(scope.wardrik), opts)
    {:ok, %{"events" => events, "next" => next}}
  end

  @doc """
  Reads the Wardrik's declarations again, has every agent take its definition as it reads now, and
  reads servers and triggers again.
  """
  @spec reload(Wardrik.Scope.t(), map()) :: {:ok, map()}
  def reload(%Wardrik.Scope{wardrik: wardrik} = scope, _input) do
    problems = Wardrik.Declarations.reload(wardrik)

    for id <- Definitions.ids(wardrik), Running.whereis(wardrik, id) != nil do
      with {:ok, definition} <- Definitions.fetch(wardrik, id),
           {:ok, opts} <- Definition.resolve(wardrik, id, definition),
           do: Running.bring(wardrik, opts)
    end

    :ok = WardrikMCP.reconcile(Wardrik.mcp(wardrik))
    :ok = WardrikTriggers.reconcile(Wardrik.triggers(wardrik))

    here = to_string(node())
    Changes.record_deployment(scope, "agents.reloaded", "deployment", %{"nodes" => [here]})
    {:ok, %{"reloaded" => [here], "problems" => problems}}
  end

  @doc "Lists the deployment's nodes, each with how many agents run on it, and how many sleep."
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

  @doc "Starts an agent again on another node, as it was."
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
