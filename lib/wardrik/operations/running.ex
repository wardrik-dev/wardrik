defmodule Wardrik.Operations.Running do
  @moduledoc """
  Finds the agents operations act on, waking them from their definitions if needed.

  A running agent is `{agent, conversation}`: the agent's own history with `conversation` `nil`,
  or one of its conversations, which runs on the agent's definition.
  """

  alias Wardrik.Definitions
  alias Wardrik.Error
  alias Wardrik.Setup

  @typedoc "An agent's ID and its conversation's, `nil` for the agent's own."
  @type key() :: {String.t(), String.t() | nil}

  @doc "Returns the key an operation's `input` names."
  @spec key(map()) :: key()
  def key(input), do: {Map.fetch!(input, "agent"), input["conversation"]}

  @doc "Returns the running agent `key`, or `nil`."
  @spec whereis(Wardrik.t(), key()) :: pid() | nil
  def whereis(wardrik, key), do: WardrikCore.whereis(Wardrik.agents(wardrik), key)

  @doc "Returns the agent `key`, waking it from its definition if needed, or a `not_found` error."
  @spec awake(Wardrik.t(), key()) :: {:ok, pid()} | {:error, Error.t()}
  def awake(wardrik, key) do
    case whereis(wardrik, key) do
      nil -> wake(wardrik, key)
      pid -> {:ok, pid}
    end
  end

  @doc "Returns whether the agent `key` is running, saved or defined."
  @spec known?(Wardrik.t(), key()) :: boolean()
  def known?(wardrik, {agent, _conversation} = key) do
    whereis(wardrik, key) != nil or Definitions.fetch(wardrik, agent) != :error or
      key in WardrikCore.list(Wardrik.agents(wardrik))
  end

  @doc "Returns the keys of the saved agent `agent` and its conversations."
  @spec saved(Wardrik.t(), String.t()) :: [key()]
  def saved(wardrik, agent),
    do: for({^agent, _conversation} = key <- WardrikCore.list(Wardrik.agents(wardrik)), do: key)

  @doc "Returns the agent `agent`'s definition, or a `not_found` error."
  @spec definition(Wardrik.t(), String.t()) :: {:ok, map()} | {:error, Error.t()}
  def definition(wardrik, agent) do
    case Definitions.fetch(wardrik, agent) do
      {:ok, definition} -> {:ok, definition}
      :error -> {:error, Error.new(:not_found, "There's no definition of #{agent}.")}
    end
  end

  @doc """
  Starts the agent `opts` describe, or reconfigures it if it's running.

  A running agent uses the new options from its next turn. A saved agent uses them as it loads.
  """
  @spec bring(Wardrik.t(), keyword()) :: {:ok, pid()} | {:error, Error.t()}
  def bring(wardrik, opts) do
    opts = Setup.agent(wardrik, opts)
    key = {Keyword.fetch!(opts, :agent_id), opts[:conversation]}

    case whereis(wardrik, key) do
      nil -> start(wardrik, key, opts)
      pid -> configured(pid, opts)
    end
  rescue
    error in ArgumentError -> {:error, Error.new(:invalid_request, Exception.message(error))}
  end

  @doc "Returns `opts` for the agent's conversation `conversation`."
  @spec held(keyword(), String.t() | nil) :: keyword()
  def held(opts, nil), do: opts
  def held(opts, conversation), do: Keyword.put(opts, :conversation, conversation)

  defp wake(wardrik, {agent, conversation}) do
    with {:ok, definition} <- definition(wardrik, agent),
         {:ok, opts} <- Wardrik.Resolution.resolve(wardrik, agent, definition),
         do: bring(wardrik, held(opts, conversation))
  end

  defp start(wardrik, key, opts) do
    case WardrikCore.start_agent(Wardrik.agents(wardrik), opts) do
      {:ok, pid} ->
        configured(pid, opts)

      {:error, {:already_started, {pid, _meta}}} ->
        configured(pid, opts)

      {:error, reason} ->
        {:error, Error.new(:unavailable, "#{describe(key)} didn't start: #{inspect(reason)}")}
    end
  end

  defp configured(pid, opts) do
    :ok = WardrikCore.configure(pid, Keyword.drop(opts, [:agent_id, :conversation]))
    {:ok, pid}
  end

  @doc "Describes the agent `key` for people: its ID, and its conversation's."
  @spec describe(key()) :: String.t()
  def describe({agent, nil}), do: agent
  def describe({agent, conversation}), do: "#{agent}'s conversation #{conversation}"
end
