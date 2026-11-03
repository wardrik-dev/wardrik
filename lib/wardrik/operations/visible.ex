defmodule Wardrik.Operations.Visible do
  @moduledoc false

  alias Wardrik.Definitions
  alias Wardrik.Error
  alias Wardrik.Operations.Running
  alias Wardrik.Scope

  @doc "Returns the keys of saved or defined agents, and their conversations, that `scope` may see."
  @spec keys(Scope.t(), map()) :: [Running.key()]
  def keys(scope, input), do: scope |> visible(input, :start) |> Enum.to_list()

  @doc """
  Returns up to `input["limit"]` of the keys `keys/2` returns, after the cursor `input["after"]`,
  and the cursor after them, `nil` if none follow. Without a limit, returns them all.
  """
  @spec page(Scope.t(), map()) :: {:ok, [Running.key()], String.t() | nil} | {:error, Error.t()}
  def page(scope, input) do
    with {:ok, start} <- start(input["after"]) do
      keys = visible(scope, input, start)

      case input["limit"] do
        nil -> {:ok, Enum.to_list(keys), nil}
        limit -> paged(Enum.take(keys, limit + 1), limit)
      end
    end
  end

  defp visible(%Scope{wardrik: wardrik} = scope, input, start) do
    (WardrikCore.list(Wardrik.agents(wardrik)) ++ Enum.map(Definitions.ids(wardrik), &{&1, nil}))
    |> Enum.uniq()
    |> Enum.sort()
    |> Stream.drop_while(&(start != :start and &1 <= start))
    |> Stream.filter(fn {agent, _conversation} -> visible?(scope, input, agent) end)
  end

  defp paged(keys, limit) when length(keys) > limit do
    page = Enum.take(keys, limit)
    {:ok, page, page |> List.last() |> cursor()}
  end

  defp paged(keys, _limit), do: {:ok, keys, nil}

  defp cursor({agent, conversation}),
    do: [agent, conversation] |> JSON.encode!() |> Base.url_encode64(padding: false)

  defp start(nil), do: {:ok, :start}

  defp start(cursor) do
    with {:ok, json} <- Base.url_decode64(cursor, padding: false),
         {:ok, [agent, conversation]} when is_binary(agent) <- JSON.decode(json) do
      {:ok, {agent, conversation}}
    else
      _unreadable -> {:error, Error.new(:invalid_request, "The cursor doesn't read.")}
    end
  end

  @doc "Returns the IDs of saved or defined agents that `input` names and `scope` may see."
  @spec agents(Scope.t(), map()) :: [String.t()]
  def agents(scope, input),
    do: scope |> keys(input) |> Enum.map(fn {agent, _conversation} -> agent end) |> Enum.uniq()

  @doc "Returns the logs that hold every agent `input` names, with its conversations."
  @spec logs(map()) :: WardrikEvents.resources()
  def logs(%{"agents" => ids}), do: Enum.uniq(ids)
  def logs(_input), do: :all

  @doc "Returns whether `input` names the agent `id`, and `scope` may see it."
  @spec visible?(Scope.t(), map(), String.t()) :: boolean()
  def visible?(scope, input, id),
    do: named?(input, id) and Wardrik.Authorizer.allows?(scope, {:agent, id})

  @doc "Returns the ID of the agent whose log holds `event`."
  @spec agent_id(map()) :: String.t()
  def agent_id(%{"agent" => agent}), do: agent

  defp named?(%{"agents" => ids}, id), do: id in ids
  defp named?(_input, _id), do: true
end
