defmodule Wardrik.Operations.Running do
  @moduledoc """
  Finds the agents operations act on: running, woken from their definition, or known though asleep.
  """

  alias Wardrik.AgentID
  alias Wardrik.Definitions
  alias Wardrik.Error
  alias Wardrik.Setup

  @doc "Returns the running agent `id`, or `nil`."
  @spec whereis(Wardrik.t(), String.t()) :: pid() | nil
  def whereis(wardrik, id), do: WardrikCore.whereis(Wardrik.agents(wardrik), id)

  @doc "Returns the agent `id`, woken from its definition if it sleeps, or a `not_found` error."
  @spec awake(Wardrik.t(), String.t()) :: {:ok, pid()} | {:error, Error.t()}
  def awake(wardrik, id) do
    case whereis(wardrik, id) do
      nil -> wake(wardrik, id)
      pid -> {:ok, pid}
    end
  end

  @doc "Returns whether `wardrik` knows the agent `id`: running, saved, or defined."
  @spec known?(Wardrik.t(), String.t()) :: boolean()
  def known?(wardrik, id) do
    whereis(wardrik, id) != nil or Definitions.fetch(wardrik, AgentID.agent(id)) != :error or
      id in WardrikCore.list(Wardrik.agents(wardrik))
  end

  @doc "Returns the definition the agent `id` runs on, its agent's for a conversation, or a `not_found` error."
  @spec definition(Wardrik.t(), String.t()) :: {:ok, map()} | {:error, Error.t()}
  def definition(wardrik, id) do
    case Definitions.fetch(wardrik, AgentID.agent(id)) do
      {:ok, definition} -> {:ok, definition}
      :error -> {:error, Error.new(:not_found, "There's no definition of #{id}.")}
    end
  end

  @doc "Returns `:ok` if the agent `id` takes a definition of its own, as a conversation doesn't."
  @spec definable(String.t()) :: :ok | {:error, Error.t()}
  def definable(id) do
    if AgentID.conversation?(id),
      do:
        {:error,
         Error.new(
           :invalid_request,
           "#{id} is a conversation. It runs on #{AgentID.agent(id)}'s definition."
         )},
      else: :ok
  end

  @doc """
  Starts the agent `opts` describe, or brings the one running to them from its next turn. An agent
  that was saved before takes them as it loads.
  """
  @spec bring(Wardrik.t(), keyword()) :: {:ok, pid()} | {:error, Error.t()}
  def bring(wardrik, opts) do
    opts = Setup.agent(wardrik, opts)
    id = Keyword.fetch!(opts, :agent_id)

    case whereis(wardrik, id) do
      nil -> start(wardrik, id, opts)
      pid -> configured(pid, opts)
    end
  rescue
    error in ArgumentError -> {:error, Error.new(:invalid_request, Exception.message(error))}
  end

  defp wake(wardrik, id) do
    with {:ok, definition} <- definition(wardrik, id),
         {:ok, opts} <- Wardrik.Resolution.resolve(wardrik, id, definition),
         do: bring(wardrik, opts)
  end

  defp start(wardrik, id, opts) do
    case WardrikCore.start_agent(Wardrik.agents(wardrik), opts) do
      {:ok, pid} ->
        configured(pid, opts)

      {:error, {:already_started, {pid, _meta}}} ->
        configured(pid, opts)

      {:error, reason} ->
        {:error, Error.new(:unavailable, "#{id} didn't start: #{inspect(reason)}")}
    end
  end

  defp configured(pid, opts) do
    :ok = WardrikCore.configure(pid, Keyword.delete(opts, :agent_id))
    {:ok, pid}
  end
end
