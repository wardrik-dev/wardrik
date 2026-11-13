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

  @doc """
  Returns the agent `key`'s `"status"`: its activity's while it runs, else `"asleep"`, or
  `"unreadable"` with the `"problem"` while its saved state can't be read.
  """
  @spec standing(Wardrik.t(), Running.key(), map()) :: map()
  def standing(wardrik, key, activity) do
    case Running.whereis(wardrik, key) do
      nil -> asleep(wardrik, key)
      _pid -> %{"status" => status(activity)}
    end
  end

  defp asleep(wardrik, key) do
    case Running.unreadable(wardrik, key) do
      {:ok, reason} -> %{"status" => "unreadable", "problem" => reason}
      :error -> %{"status" => "asleep"}
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

    %{
      "id" => agent,
      "node" => placed(wardrik, key),
      "pending" => activity["pending"],
      "next_run" => next_run,
      "spent_today" => spent
    }
    |> Map.merge(described(wardrik, agent))
    |> Map.merge(standing(wardrik, key, activity))
    |> conversation(conversation)
  end

  @doc """
  Returns the agent's `"description"` and `"model"`, from its definition, where it has them. The
  model falls back to the deployment's.
  """
  @spec described(Wardrik.t(), String.t()) :: map()
  def described(wardrik, agent) do
    definition =
      case Wardrik.Definitions.fetch(wardrik, agent) do
        {:ok, definition} -> Map.merge(wardrik.defaults, definition)
        :error -> wardrik.defaults
      end

    definition
    |> Map.take(["description", "model"])
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
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

  @doc """
  Returns the paging options in `input`: `"order"`, with `"after"` oldest first or `"before"`
  newest first, and `"limit"`.
  """
  @spec paging(map()) :: {:ok, keyword()} | {:error, Error.t()}
  def paging(%{"order" => "newest", "after" => _after}),
    do:
      {:error, Error.new(:invalid_request, "Newest first reads before a cursor, not after one.")}

  def paging(%{"order" => "newest"} = input),
    do: {:ok, [order: :newest, before: input["before"], limit: input["limit"]]}

  def paging(%{"before" => _before}),
    do: {:error, Error.new(:invalid_request, "before reads newest first; set order to newest.")}

  def paging(input), do: {:ok, [after: input["after"], limit: input["limit"]]}

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
