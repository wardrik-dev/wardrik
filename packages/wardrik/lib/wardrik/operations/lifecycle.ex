defmodule Wardrik.Operations.Lifecycle do
  @moduledoc false

  alias Wardrik.Definition
  alias Wardrik.Definitions
  alias Wardrik.Error
  alias Wardrik.Operations.Agent
  alias Wardrik.Operations.Changes
  alias Wardrik.Operations.Running
  alias Wardrik.Operations.Snapshot
  alias Wardrik.Scope
  alias Wardrik.Sleeper

  @doc "Defines an agent. Starts it, or reconfigures it if it's running."
  @spec define(Scope.t(), map()) :: {:ok, map()} | {:error, Error.t()}
  def define(%Scope{wardrik: wardrik} = scope, %{"agent" => id} = input) do
    definition = input |> Map.delete("agent") |> Definition.named()

    with :ok <- bounded(wardrik, id, scope.policy),
         :ok <- written_after(wardrik, id, definition["policy"]),
         {:ok, opts} <- Wardrik.Resolution.resolve(wardrik, id, definition),
         {:ok, _pid} <- Running.bring(wardrik, opts),
         :ok <- saved(wardrik, id, definition) do
      Sleeper.watch(wardrik, id)
      Changes.record(scope, type: "agent.defined", agent: id)
      Agent.read(scope, %{"agent" => id})
    end
  end

  defp saved(wardrik, id, definition) do
    triggers = Map.get(definition, "triggers", [])

    with :ok <- Definitions.put(wardrik, id, definition),
         :ok <- WardrikTriggers.put(Wardrik.triggers(wardrik), id, triggers) do
      :ok
    else
      {:error, reason} ->
        {:error,
         Error.new(:unavailable, "#{id} wasn't saved: #{inspect(reason)}. Define it again.")}
    end
  end

  @doc """
  Returns the agent's definition, tools it names that aren't there yet, and its next runs.
  """
  @spec definition(Scope.t(), map()) :: {:ok, map()} | {:error, Error.t()}
  def definition(%Scope{wardrik: wardrik}, %{"agent" => id}) do
    with {:ok, definition} <- Running.definition(wardrik, id) do
      {:ok,
       %{
         "definition" => definition,
         "missing" => Wardrik.Resolution.missing(wardrik, id, definition),
         "next_runs" => Snapshot.next_runs(wardrik, id)
       }}
    end
  end

  @doc "Stops the agent, and deletes its history, its conversations and its definition."
  @spec forget(Scope.t(), map()) :: {:ok, nil} | {:error, Error.t()}
  def forget(%Scope{wardrik: wardrik} = scope, %{"agent" => id}) do
    with :ok <- Snapshot.known(wardrik, {id, nil}),
         :ok <- undeclared(wardrik, id),
         :ok <- forgotten(wardrik, id) do
      Changes.record(scope, type: "agent.forgotten", agent: id)
      {:ok, nil}
    end
  end

  @doc "Starts the agent from its definition, unless it's running."
  @spec spawn(Scope.t(), map()) :: {:ok, map()} | {:error, Error.t()}
  def spawn(%Scope{wardrik: wardrik} = scope, %{"agent" => id}) do
    asleep? = Running.whereis(wardrik, id) == nil

    with {:ok, _pid} <- Running.awake(wardrik, id) do
      if asleep?, do: Changes.record(scope, type: "agent.spawned", agent: id)
      {:ok, %{"agent" => Snapshot.summary(wardrik, {id, nil})}}
    end
  end

  @doc "Stops the agent but keeps its history. It sleeps until something asks it."
  @spec stop(Scope.t(), map()) :: {:ok, map()} | {:error, Error.t()}
  def stop(%Scope{wardrik: wardrik} = scope, input) do
    key = Running.key(input)

    with :ok <- Snapshot.known(wardrik, key) do
      stopped(scope, key, Running.whereis(wardrik, key))
      {:ok, %{"agent" => %{Snapshot.summary(wardrik, key) | "status" => "asleep"}}}
    end
  end

  @doc "Clears the agent's history, and restarts it from its definition."
  @spec clear(Scope.t(), map()) :: {:ok, map()} | {:error, Error.t()}
  def clear(%Scope{wardrik: wardrik} = scope, input) do
    {agent, conversation} = key = Running.key(input)

    with :ok <- Snapshot.known(wardrik, key),
         :ok <- idle(wardrik, key),
         {:ok, definition} <- Running.definition(wardrik, agent),
         {:ok, opts} <- Wardrik.Resolution.resolve(wardrik, agent, definition),
         before = messages(wardrik, key),
         :ok <- WardrikCore.delete(Wardrik.agents(wardrik), key),
         {:ok, _pid} <- Running.bring(wardrik, Running.held(opts, conversation)) do
      subject = WardrikEvents.CloudEvent.subject(agent)
      cleared = {"conversation.cleared", subject, %{"messages_before" => before}}
      :ok = WardrikEvents.append(Wardrik.events(wardrik), key, cleared)
      Changes.record(scope, type: "agent.cleared", agent: key)
      Agent.read(scope, input)
    end
  end

  @doc "Lists the tool calls the agent is running, with how long each has run."
  @spec calls(Scope.t(), map()) :: {:ok, map()} | {:error, Error.t()}
  def calls(%Scope{wardrik: wardrik}, input) do
    key = Running.key(input)

    with {:ok, _pid} <- Snapshot.running(wardrik, key) do
      now = DateTime.utc_now()

      calls =
        for %{"type" => "wardrik.tool_call.started", "tool" => tool, "since" => since} <-
              WardrikEvents.activity(Wardrik.events(wardrik), key)["doing"],
            do: %{
              "id" => tool["call"]["id"],
              "name" => tool["name"],
              "elapsed_ms" => elapsed(since, now)
            }

      {:ok, %{"calls" => calls}}
    end
  end

  @doc "Kills one running tool call. The model gets an error."
  @spec kill(Scope.t(), map()) :: {:ok, nil} | {:error, Error.t()}
  def kill(%Scope{wardrik: wardrik} = scope, %{"call" => call} = input) do
    key = Running.key(input)

    with {:ok, pid} <- Snapshot.running(wardrik, key) do
      case WardrikCore.kill(pid, call) do
        :ok ->
          Changes.record(scope,
            type: "call.killed",
            agent: key,
            data: %{"call" => %{"id" => call}}
          )

          {:ok, nil}

        {:error, :not_running} ->
          {:error, Error.new(:not_found, "#{Running.describe(key)} isn't running #{call}.")}
      end
    end
  end

  @doc "Stops the agent and deletes all its data, including its conversations."
  @spec forgotten(Wardrik.t(), String.t()) :: :ok | {:error, Error.t()}
  def forgotten(wardrik, id) do
    with :ok <- deleted(wardrik, id),
         :ok <- Definitions.delete(wardrik, id),
         :ok <- WardrikTriggers.put(Wardrik.triggers(wardrik), id, []) do
      :ok
    else
      {:error, reason} ->
        {:error, Error.new(:unavailable, "#{id} wasn't forgotten: #{inspect(reason)}")}
    end
  end

  defp deleted(wardrik, id) do
    deleted =
      for key <- Enum.uniq([{id, nil} | Running.saved(wardrik, id)]),
          do: WardrikCore.delete(Wardrik.agents(wardrik), key)

    Enum.find(deleted, :ok, &(&1 != :ok))
  end

  defp written_after(wardrik, id, %{"allow_after" => _rules}) do
    if Wardrik.Declarations.declared?(wardrik, id),
      do: :ok,
      else:
        {:error,
         Error.new(
           :invalid_request,
           "A definition writes allow_after only in an agent file; name a policy that has it."
         )}
  end

  defp written_after(_wardrik, _id, _policy), do: :ok

  @doc "Returns `:ok`, or `conflict` if the agent `id` is declared."
  @spec undeclared(Wardrik.t(), String.t()) :: :ok | {:error, Error.t()}
  def undeclared(wardrik, id) do
    if Wardrik.Declarations.declared?(wardrik, id),
      do:
        {:error,
         Error.new(
           :conflict,
           "#{id} is declared by a file. Remove the file and reload to forget it."
         )},
      else: :ok
  end

  defp bounded(_wardrik, _id, nil), do: :ok
  defp bounded(wardrik, id, name), do: Definitions.put_boundary(wardrik, id, name)

  defp stopped(_scope, _key, nil), do: :ok

  defp stopped(scope, key, pid) do
    :ok = WardrikCore.stop(pid)
    Changes.record(scope, type: "agent.stopped", agent: key)
  end

  defp idle(wardrik, key) do
    case Snapshot.status(WardrikEvents.activity(Wardrik.events(wardrik), key)) do
      "idle" ->
        :ok

      status ->
        {:error,
         Error.new(:conflict, "#{Running.describe(key)} is #{status}; clear it once it's idle.")}
    end
  end

  defp messages(wardrik, key) do
    case Running.whereis(wardrik, key) do
      nil -> 0
      pid -> length(WardrikCore.history(pid))
    end
  end

  defp elapsed(since, now) do
    {:ok, started, _offset} = DateTime.from_iso8601(since)
    max(DateTime.diff(now, started, :millisecond), 0)
  end
end
