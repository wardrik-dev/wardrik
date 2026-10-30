defmodule Wardrik.Operations.Snapshot do
  @moduledoc "Reads agents' status and logs for operations."

  alias Wardrik.AgentID
  alias Wardrik.Error
  alias Wardrik.Operations.Running
  alias Wardrik.Scope

  @doc "Returns the agent `id`'s name. A conversation has its agent's name."
  @spec name(String.t()) :: String.t()
  def name(id) do
    {:ok, %AgentID{name: name}} = AgentID.parse(id)
    name
  end

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

  @doc "Returns `\"asleep\"` if the agent `id` isn't running, or else its `status/1`."
  @spec state(Wardrik.t(), String.t(), map()) :: String.t()
  def state(wardrik, id, activity) do
    case Running.whereis(wardrik, id) do
      nil -> "asleep"
      _pid -> status(activity)
    end
  end

  @doc "Returns the agent `id`'s summary, as lists show it."
  @spec summary(Wardrik.t(), String.t()) :: map()
  def summary(wardrik, id) do
    activity = WardrikEvents.activity(Wardrik.events(wardrik), id)

    %{
      "id" => id,
      "name" => name(id),
      "status" => state(wardrik, id, activity),
      "node" => placed(wardrik, id),
      "pending" => activity["pending"],
      "next_run" => next_run(wardrik, id),
      "spent_today" => Wardrik.Spending.today(wardrik, id)
    }
  end

  @doc "Returns when each of the agent `id`'s triggers runs next, by name. Webhooks are `nil`."
  @spec next_runs(Wardrik.t(), String.t()) :: %{String.t() => String.t() | nil}
  def next_runs(wardrik, id) do
    for {trigger, next_at} <- WardrikTriggers.list(Wardrik.triggers(wardrik), id),
        into: %{},
        do: {trigger.name, next_at && DateTime.to_iso8601(next_at)}
  end

  @doc "Returns when the agent `id`'s next scheduled trigger runs, or `nil`."
  @spec next_run(Wardrik.t(), String.t()) :: String.t() | nil
  def next_run(wardrik, id) do
    wardrik
    |> Wardrik.triggers()
    |> WardrikTriggers.list(id)
    |> Enum.map(fn {_trigger, next_at} -> next_at end)
    |> Enum.reject(&is_nil/1)
    |> Enum.min(DateTime, fn -> nil end)
    |> then(&(&1 && DateTime.to_iso8601(&1)))
  end

  @doc "Returns the node the agent `id` runs on, or `nil` if it's asleep."
  @spec placed(Wardrik.t(), String.t()) :: String.t() | nil
  def placed(wardrik, id) do
    case Running.whereis(wardrik, id) do
      nil -> nil
      pid -> to_string(node(pid))
    end
  end

  @doc "Returns `:ok` if the agent `id` exists, or a `not_found` error."
  @spec known(Wardrik.t(), String.t()) :: :ok | {:error, Error.t()}
  def known(wardrik, id) do
    if Running.known?(wardrik, id),
      do: :ok,
      else: {:error, Error.new(:not_found, "There's no agent #{id}.")}
  end

  @doc "Returns the running agent `id`, or a `not_found` error if it's asleep."
  @spec running(Wardrik.t(), String.t()) :: {:ok, pid()} | {:error, Error.t()}
  def running(wardrik, id) do
    with :ok <- known(wardrik, id) do
      case Running.whereis(wardrik, id) do
        nil -> {:error, Error.new(:not_found, "#{id} sleeps.")}
        pid -> {:ok, pid}
      end
    end
  end

  @doc "Returns whether `event` is one of `types`. Always `true` if `types` is `nil`."
  @spec typed?(map(), [String.t()] | nil) :: boolean()
  def typed?(_event, nil), do: true
  def typed?(%{"type" => "wardrik.events.dropped"}, _types), do: true
  def typed?(%{"type" => type}, types), do: type in types

  @doc "Returns a page of the logs `patterns` cover."
  @spec page(Scope.t(), [String.t()], keyword()) :: {:ok, map()} | {:error, Error.t()}
  def page(%Scope{wardrik: wardrik}, patterns, opts) do
    wardrik
    |> Wardrik.events()
    |> WardrikEvents.page(patterns, Enum.reject(opts, &match?({_key, nil}, &1)))
    |> cursor_read()
  end

  @doc "Streams the logs `patterns` cover."
  @spec stream(Scope.t(), [String.t()], keyword()) :: {:ok, Enumerable.t()} | {:error, Error.t()}
  def stream(%Scope{wardrik: wardrik}, patterns, opts) do
    wardrik
    |> Wardrik.events()
    |> WardrikEvents.stream(patterns, Enum.reject(opts, &match?({_key, nil}, &1)))
    |> cursor_read()
  end

  defp cursor_read({:ok, read}), do: {:ok, read}

  defp cursor_read({:error, :invalid_cursor}),
    do: {:error, Error.new(:invalid_request, "The cursor doesn't read.")}
end
