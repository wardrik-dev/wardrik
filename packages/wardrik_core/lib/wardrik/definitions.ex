defmodule Wardrik.Definitions do
  @moduledoc """
  What `Wardrik` does with a host's `Wardrik.Definition` beyond one call:
  read every node's again, ask whether one is kept, and forget one.
  """

  alias Wardrik.Definition

  @doc """
  Reads every definition again on each of `nodes`, through the definitions
  of `host`, one after another.
  """
  @spec reload_on(Wardrik.Host.t(), [node()]) :: :ok
  def reload_on(host, nodes) when is_list(nodes) do
    args = [Wardrik.Host.definitions(host), [host: host]]
    Enum.each(nodes, &(:ok = :erpc.call(&1, Definition, :reload, args, :timer.minutes(1))))
  end

  @doc "Whether the definitions of `host` keep one of the agent `id`."
  @spec kept?(Wardrik.Host.t(), Wardrik.AgentID.t()) :: boolean()
  def kept?(host, id),
    do: match?({:ok, _definition}, Definition.get(Wardrik.Host.definitions(host), id))

  @doc """
  Forgets the definition the definitions of `host` keep of the agent `id`,
  as the agent is forgotten: whether one was kept, or a conflict where they
  refuse.
  """
  @spec forget(Wardrik.Host.t(), Wardrik.AgentID.t()) ::
          {:ok, boolean()} | {:error, :conflict, String.t()}
  def forget(host, id) do
    case Definition.delete(Wardrik.Host.definitions(host), id) do
      :ok -> {:ok, true}
      {:error, :not_found} -> {:ok, false}
      {:error, :conflict, why} -> {:error, :conflict, why}
    end
  end
end
