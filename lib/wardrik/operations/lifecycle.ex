defmodule Wardrik.Operations.Lifecycle do
  @moduledoc """
  The operations that make an agent what it is: defining, starting, stopping, clearing and
  forgetting it, and stopping a call it runs.
  """

  alias Wardrik.Definition
  alias Wardrik.Definitions
  alias Wardrik.Error
  alias Wardrik.Operations.Agent
  alias Wardrik.Operations.Changes
  alias Wardrik.Operations.Running
  alias Wardrik.Operations.Snapshot
  alias Wardrik.Scope
  alias Wardrik.Sleeper

  @doc "Starts the agent a definition describes, or brings the one running to it."
  @spec define(Scope.t(), map()) :: {:ok, map()} | {:error, Error.t()}
  def define(%Scope{wardrik: wardrik} = scope, %{"agent" => id} = input) do
    definition = Map.delete(input, "agent")

    with {:ok, opts} <- Definition.resolve(wardrik, id, definition),
         {:ok, _pid} <- Running.bring(wardrik, opts),
         :ok <- Definitions.put(wardrik, id, definition) do
      Sleeper.watch(wardrik, id)
      Changes.record(scope, "agent.defined", id)
      Agent.read(scope, %{"agent" => id})
    end
  end

  @doc "Reads the agent's definition, and the tools it names that offer nothing yet."
  @spec definition(Scope.t(), map()) :: {:ok, map()} | {:error, Error.t()}
  def definition(%Scope{wardrik: wardrik}, %{"agent" => id}) do
    with {:ok, definition} <- Running.definition(wardrik, id) do
      {:ok, %{"definition" => definition, "missing" => Definition.missing(wardrik, definition)}}
    end
  end

  @doc "Stops the agent, and deletes its conversation and definition."
  @spec forget(Scope.t(), map()) :: {:ok, nil} | {:error, Error.t()}
  def forget(%Scope{wardrik: wardrik} = scope, %{"agent" => id}) do
    with :ok <- Snapshot.known(wardrik, id),
         :ok <- forgotten(wardrik, id) do
      Changes.record(scope, "agent.forgotten", id)
      {:ok, nil}
    end
  end

  @doc "Starts the agent from its definition, unless it's running."
  @spec spawn(Scope.t(), map()) :: {:ok, map()} | {:error, Error.t()}
  def spawn(%Scope{wardrik: wardrik} = scope, %{"agent" => id}) do
    asleep? = Running.whereis(wardrik, id) == nil

    with {:ok, _pid} <- Running.awake(wardrik, id) do
      if asleep?, do: Changes.record(scope, "agent.spawned", id)
      {:ok, %{"agent" => Snapshot.summary(wardrik, id)}}
    end
  end

  @doc "Stops the agent, keeping its conversation, so it sleeps until something asks it."
  @spec stop(Scope.t(), map()) :: {:ok, map()} | {:error, Error.t()}
  def stop(%Scope{wardrik: wardrik} = scope, %{"agent" => id}) do
    with :ok <- Snapshot.known(wardrik, id) do
      stopped(scope, id, Running.whereis(wardrik, id))
      {:ok, %{"agent" => %{Snapshot.summary(wardrik, id) | "status" => "asleep"}}}
    end
  end

  @doc "Empties the agent's conversation, and starts it again from its definition."
  @spec clear(Scope.t(), map()) :: {:ok, map()} | {:error, Error.t()}
  def clear(%Scope{wardrik: wardrik} = scope, %{"agent" => id}) do
    with :ok <- Snapshot.known(wardrik, id),
         :ok <- idle(wardrik, id),
         {:ok, definition} <- Running.definition(wardrik, id),
         {:ok, opts} <- Definition.resolve(wardrik, id, definition),
         :ok <- WardrikCore.delete(Wardrik.agents(wardrik), id),
         {:ok, _pid} <- Running.bring(wardrik, opts) do
      Changes.record(scope, "agent.cleared", id)
      Agent.read(scope, %{"agent" => id})
    end
  end

  @doc "Lists the tool calls the agent is running, each with how long it has run."
  @spec calls(Scope.t(), map()) :: {:ok, map()} | {:error, Error.t()}
  def calls(%Scope{wardrik: wardrik}, %{"agent" => id}) do
    with {:ok, _pid} <- Snapshot.running(wardrik, id) do
      now = DateTime.utc_now()

      calls =
        for %{"type" => "wardrik.tool_call.started", "tool" => tool, "since" => since} <-
              WardrikEvents.activity(Wardrik.events(wardrik), id)["doing"],
            do: %{
              "id" => tool["call"]["id"],
              "name" => tool["name"],
              "elapsed_ms" => elapsed(since, now)
            }

      {:ok, %{"calls" => calls}}
    end
  end

  @doc "Stops one tool call the agent is running. The model is answered with an error for it."
  @spec kill(Scope.t(), map()) :: {:ok, nil} | {:error, Error.t()}
  def kill(%Scope{wardrik: wardrik} = scope, %{"agent" => id, "call" => call}) do
    with {:ok, pid} <- Snapshot.running(wardrik, id) do
      case WardrikCore.kill(pid, call) do
        :ok ->
          Changes.record(scope, "call.killed", id, %{"call" => %{"id" => call}})
          {:ok, nil}

        {:error, :not_running} ->
          {:error, Error.new(:not_found, "#{id} isn't running #{call}.")}
      end
    end
  end

  @doc "Stops the agent and deletes everything it had. Returns `:ok`, or why it couldn't."
  @spec forgotten(Wardrik.t(), String.t()) :: :ok | {:error, Error.t()}
  def forgotten(wardrik, id) do
    with :ok <- WardrikCore.delete(Wardrik.agents(wardrik), id),
         :ok <- Definitions.delete(wardrik, id) do
      :ok
    else
      {:error, reason} ->
        {:error, Error.new(:unavailable, "#{id} wasn't forgotten: #{inspect(reason)}")}
    end
  end

  defp stopped(_scope, _id, nil), do: :ok

  defp stopped(scope, id, pid) do
    :ok = WardrikCore.stop(pid)
    Changes.record(scope, "agent.stopped", id)
  end

  defp idle(wardrik, id) do
    case Snapshot.status(WardrikEvents.activity(Wardrik.events(wardrik), id)) do
      "idle" -> :ok
      status -> {:error, Error.new(:conflict, "#{id} is #{status}; clear it once it's idle.")}
    end
  end

  defp elapsed(since, now) do
    {:ok, started, _offset} = DateTime.from_iso8601(since)
    max(DateTime.diff(now, started, :millisecond), 0)
  end
end
