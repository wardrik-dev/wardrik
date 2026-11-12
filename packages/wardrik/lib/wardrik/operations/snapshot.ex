defmodule Wardrik.Operations.Snapshot do
  @moduledoc false

  alias Wardrik.Error
  alias Wardrik.Operations.Running
  alias Wardrik.Scope

  @doc ~S|Returns `"idle"`, `"running"`, or `"parked"` when waiting on a person.|
  @spec status(map()) :: String.t()
  def status(%{"doing" => []}), do: "idle"

  def status(%{"doing" => doing}) do
    if Enum.any?(doing, &(&1["type"] == "wardrik.run.interrupted")),
      do: "parked",
      else: "running"
  end

  @doc "Returns the calls the agent waits on a person for."
  @spec interrupts(map()) :: [map()]
  def interrupts(%{"doing" => doing}) do
    Enum.flat_map(doing, fn
      %{"type" => "wardrik.run.interrupted", "interrupts" => interrupts} -> interrupts
      _doing -> []
    end)
  end

  @doc "Returns the agent `key`'s status, or `\"asleep\"`."
  @spec state(Wardrik.t(), Running.key(), map()) :: String.t()
  def state(wardrik, key, activity) do
    case Running.whereis(wardrik, key) do
      nil -> "asleep"
      _pid -> status(activity)
    end
  end

  @doc "Returns the agent `key`'s summary, as lists show it."
  @spec summary(Wardrik.t(), Running.key()) :: map()
  def summary(wardrik, {agent, _conversation} = key),
    do: summarized(wardrik, key, next_run(wardrik, agent), Wardrik.Spending.today(wardrik, agent))

  @doc "Returns the summaries of `keys`, reading their triggers and spending once for all."
  @spec summaries(Wardrik.t(), [Running.key()]) :: [map()]
  def summaries(wardrik, keys) do
    agents = keys |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
    next_runs = Wardrik.Triggers.next_runs(Wardrik.triggers(wardrik), agents)
    spent = Wardrik.Spending.by_agent(wardrik, agents)

    for {agent, _conversation} = key <- keys,
        do: summarized(wardrik, key, iso8601(next_runs[agent]), Map.fetch!(spent, agent))
  end

  defp summarized(wardrik, {agent, conversation} = key, next_run, spent) do
    activity = Wardrik.EventLog.activity(Wardrik.events(wardrik), key)

    conversation(
      %{
        "id" => agent,
        "status" => state(wardrik, key, activity),
        "node" => placed(wardrik, key),
        "pending" => activity["pending"],
        "next_run" => next_run,
        "spent_today" => spent
      },
      conversation
    )
  end

  @doc "Puts `conversation` in `output`, where it's one."
  @spec conversation(map(), String.t() | nil) :: map()
  def conversation(output, nil), do: output
  def conversation(output, conversation), do: Map.put(output, "conversation", conversation)

  @doc "Returns each trigger's next run by name. Webhooks are `nil`."
  @spec next_runs(Wardrik.t(), String.t()) :: %{String.t() => String.t() | nil}
  def next_runs(wardrik, id) do
    for {trigger, next_at} <- Wardrik.Triggers.list(Wardrik.triggers(wardrik), id),
        into: %{},
        do: {trigger.name, next_at && DateTime.to_iso8601(next_at)}
  end

  @doc "Returns when the agent `id`'s next scheduled trigger runs, or `nil`."
  @spec next_run(Wardrik.t(), String.t()) :: String.t() | nil
  def next_run(wardrik, id) do
    wardrik
    |> Wardrik.triggers()
    |> Wardrik.Triggers.list(id)
    |> Enum.map(fn {_trigger, next_at} -> next_at end)
    |> Enum.reject(&is_nil/1)
    |> Enum.min(DateTime, fn -> nil end)
    |> iso8601()
  end

  defp iso8601(nil), do: nil
  defp iso8601(at), do: DateTime.to_iso8601(at)

  @doc "Returns the node the agent `key` runs on, or `nil` if it's asleep."
  @spec placed(Wardrik.t(), Running.key()) :: String.t() | nil
  def placed(wardrik, key) do
    case Running.whereis(wardrik, key) do
      nil -> nil
      pid -> to_string(node(pid))
    end
  end

  @doc "Returns `:ok` if the agent `key` exists, or a `not_found` error."
  @spec known(Wardrik.t(), Running.key()) :: :ok | {:error, Error.t()}
  def known(wardrik, key) do
    if Running.known?(wardrik, key),
      do: :ok,
      else: {:error, Error.new(:not_found, "There's no agent #{Running.describe(key)}.")}
  end

  @doc "Returns the running agent `key`, or a `not_found` error if it's asleep."
  @spec running(Wardrik.t(), Running.key()) :: {:ok, pid()} | {:error, Error.t()}
  def running(wardrik, key) do
    with :ok <- known(wardrik, key) do
      case Running.whereis(wardrik, key) do
        nil -> {:error, Error.new(:not_found, "#{Running.describe(key)} sleeps.")}
        pid -> {:ok, pid}
      end
    end
  end

  @doc "Returns whether `event` is one of `types`. Always `true` if `types` is `nil`."
  @spec typed?(map(), [String.t()] | nil) :: boolean()
  def typed?(_event, nil), do: true
  def typed?(%{"type" => "wardrik.events.dropped"}, _types), do: true
  def typed?(%{"type" => type}, types), do: type in types

  @doc "Returns a page of the given logs."
  @spec page(Scope.t(), Wardrik.EventLog.resources(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def page(%Scope{wardrik: wardrik}, resources, opts) do
    wardrik
    |> Wardrik.events()
    |> Wardrik.EventLog.page(resources, Enum.reject(opts, &match?({_key, nil}, &1)))
    |> cursor_read()
  end

  @doc "Streams the given logs."
  @spec stream(Scope.t(), Wardrik.EventLog.resources(), keyword()) ::
          {:ok, Enumerable.t()} | {:error, Error.t()}
  def stream(%Scope{wardrik: wardrik}, resources, opts) do
    wardrik
    |> Wardrik.events()
    |> Wardrik.EventLog.stream(resources, Enum.reject(opts, &match?({_key, nil}, &1)))
    |> cursor_read()
  end

  defp cursor_read({:ok, read}), do: {:ok, read}

  defp cursor_read({:error, :invalid_cursor}),
    do: {:error, Error.new(:invalid_request, "The cursor doesn't read.")}
end
