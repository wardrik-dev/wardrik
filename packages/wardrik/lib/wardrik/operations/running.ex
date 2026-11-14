defmodule Wardrik.Operations.Running do
  @moduledoc "Finds the agents operations act on, waking them if needed."

  @behaviour WardrikCore.Configure

  alias Wardrik.Definitions
  alias Wardrik.Error
  alias Wardrik.Setup
  alias Wardrik.Store.Durable

  @typedoc "An agent's ID and its conversation's, `nil` for the agent's own."
  @type key() :: {String.t(), String.t() | nil}

  @typedoc "An agent's ID, for its own history, or a `t:key/0`."
  @type agent() :: String.t() | key()

  @doc "Returns the key an operation's `input` names."
  @spec key(map()) :: key()
  def key(input), do: {Map.fetch!(input, "agent"), input["conversation"]}

  @doc "Returns the running `agent`, or `nil`."
  @spec whereis(Wardrik.t(), agent()) :: pid() | nil
  def whereis(wardrik, agent) do
    wardrik
    |> Wardrik.agents()
    |> WardrikCore.whereis(agent)
  end

  @doc "Returns `agent`, waking it from its definition if needed, or a `not_found` error."
  @spec awake(Wardrik.t(), agent()) :: {:ok, pid()} | {:error, Error.t()}
  def awake(wardrik, agent) when is_binary(agent), do: awake(wardrik, {agent, nil})

  def awake(wardrik, key) do
    case whereis(wardrik, key) do
      nil -> wake(wardrik, key)
      pid -> {:ok, pid}
    end
  end

  @doc "Returns whether the agent `key` is running, saved or defined."
  @spec known?(Wardrik.t(), key()) :: boolean()
  def known?(wardrik, {agent, _conversation} = key) do
    agents = Wardrik.agents(wardrik)

    whereis(wardrik, key) != nil or Definitions.fetch(wardrik, agent) != :error or
      key in WardrikCore.list(agents)
  end

  @doc "Returns the keys of the saved agent `agent` and its conversations."
  @spec saved(Wardrik.t(), String.t()) :: [key()]
  def saved(wardrik, agent) do
    agents = Wardrik.agents(wardrik)
    for {^agent, _conversation} = key <- WardrikCore.list(agents), do: key
  end

  @doc "Returns the agent `agent`'s definition, or a `not_found` error."
  @spec definition(Wardrik.t(), String.t()) :: {:ok, map()} | {:error, Error.t()}
  def definition(wardrik, agent) do
    case Definitions.fetch(wardrik, agent) do
      {:ok, definition} -> {:ok, definition}
      :error -> {:error, Error.new(:not_found, "There's no definition of #{agent}.")}
    end
  end

  @doc """
  Starts the agent `opts` describe, or reconfigures it from its next turn.
  """
  @spec bring(Wardrik.t(), keyword()) :: {:ok, pid()} | {:error, Error.t()}
  def bring(wardrik, opts) do
    opts = Setup.agent(wardrik, opts)
    key = {Keyword.fetch!(opts, :agent_id), opts[:conversation]}

    case whereis(wardrik, key) do
      nil -> start(wardrik, key, opts)
      pid -> configured(wardrik, key, pid, opts)
    end
  rescue
    error in ArgumentError -> {:error, Error.new(:invalid_request, Exception.message(error))}
  end

  @doc "Returns `opts` for the agent's conversation `conversation`."
  @spec held(keyword(), String.t() | nil) :: keyword()
  def held(opts, nil), do: opts
  def held(opts, conversation), do: Keyword.put(opts, :conversation, conversation)

  @doc """
  Gives an agent that loads by itself, as after a crash, its settings from its definition, as
  waking it would. An agent started from code without one waits until it's started again.
  """
  @impl WardrikCore.Configure
  def configure({agent, conversation}, name) do
    wardrik = Wardrik.Instance.fetch!(name)

    with {:ok, definition} <- definition(wardrik, agent),
         {:ok, opts} <- Wardrik.Resolution.resolve(wardrik, agent, definition) do
      opts = Setup.agent(wardrik, held(opts, conversation))
      {:ok, Keyword.drop(opts, [:agent_id, :conversation])}
    else
      {:error, _reason} -> :none
    end
  end

  defp wake(wardrik, {agent, conversation}) do
    with {:ok, definition} <- definition(wardrik, agent),
         {:ok, opts} <- Wardrik.Resolution.resolve(wardrik, agent, definition),
         do: bring(wardrik, held(opts, conversation))
  end

  defp start(wardrik, key, opts) do
    agents = Wardrik.agents(wardrik)

    case WardrikCore.start_agent(agents, opts) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, {:already_started, {pid, _meta}}} ->
        configured(wardrik, key, pid, opts)

      # Another node started it first, and answered from there.
      {:error, {:already_started, pid}} when is_pid(pid) ->
        configured(wardrik, key, pid, opts)

      {:error, {:unreadable, reason}} ->
        unreadable(wardrik, key, reason)

      {:error, reason} ->
        {:error, Error.new(:unavailable, "#{describe(key)} didn't start: #{inspect(reason)}")}
    end
  end

  @doc """
  Returns why the agent `key`'s saved state can't be read, once a read found it so, or
  `:error`.
  """
  @spec unreadable(Wardrik.t(), key()) :: {:ok, String.t()} | :error
  def unreadable(wardrik, key), do: Durable.noted(wardrik.store, saved_key(wardrik, key))

  @doc """
  Starts over each of the agent `agent`'s saved states that can't be read, its own and its
  conversations'. Returns what was started over, and why.
  """
  @spec reset_unreadable(Wardrik.t(), String.t()) :: [String.t()]
  def reset_unreadable(wardrik, agent) do
    for key <- saved(wardrik, agent),
        saved = saved_key(wardrik, key),
        {:error, reason} <- [Durable.check(wardrik.store, saved)] do
      :ok = Durable.discard(wardrik.store, saved)
      "#{describe(key)} started over, as its saved state couldn't be read: #{reason}."
    end
  end

  defp saved_key(wardrik, key) do
    wardrik
    |> Wardrik.agents()
    |> WardrikCore.saved_key(key)
  end

  defp configured(wardrik, key, pid, opts) do
    case WardrikCore.configure(pid, Keyword.drop(opts, [:agent_id, :conversation])) do
      :ok -> {:ok, pid}
      {:error, {:unreadable, reason}} -> unreadable(wardrik, key, reason)
    end
  end

  # Noted, so `unreadable/2` answers and defining the agent again starts it over.
  defp unreadable(wardrik, key, reason) do
    :ok = Durable.note(wardrik.store, saved_key(wardrik, key), reason)

    {:error,
     Error.new(
       :conflict,
       "#{describe(key)} can't start, as its saved state can't be read: #{reason}. Define it again to start it over; its definition, files and events stay."
     )}
  end

  @doc "Describes the agent `key` for people: its ID, and its conversation's."
  @spec describe(key()) :: String.t()
  def describe({agent, nil}), do: agent
  def describe({agent, conversation}), do: "#{agent}'s conversation #{conversation}"
end
