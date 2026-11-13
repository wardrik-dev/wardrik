defmodule Wardrik.Operations.Agent do
  @moduledoc false

  alias Wardrik.Error
  alias Wardrik.EventLog.Cursor
  alias Wardrik.EventLog.Runs
  alias Wardrik.EventLog.Timeline
  alias Wardrik.JSON
  alias Wardrik.Operations.Changes
  alias Wardrik.Operations.Running
  alias Wardrik.Operations.Snapshot
  alias WardrikCore.Authorization

  @doc "Returns what the agent is doing now."
  @spec read(Wardrik.Scope.t(), map()) :: {:ok, map()} | {:error, Error.t()}
  def read(scope, input) do
    {agent, conversation} = key = Running.key(input)

    with :ok <- Snapshot.known(scope.wardrik, key) do
      events = Wardrik.events(scope.wardrik)
      activity = Wardrik.EventLog.activity(events, key)

      {:ok,
       %{
         "agent" => %{"id" => agent},
         "node" => Snapshot.placed(scope.wardrik, key),
         "pending" => activity["pending"],
         "next_run" => Snapshot.next_run(scope.wardrik, agent),
         "spent_today" => Wardrik.Spending.today(scope.wardrik, agent),
         "activity" => activity,
         "interrupts" => Snapshot.interrupts(activity),
         "cursor" => Wardrik.EventLog.head(events, [key])
       }
       |> Map.merge(Snapshot.described(scope.wardrik, agent))
       |> Map.merge(Snapshot.standing(scope.wardrik, key, activity))
       |> Snapshot.conversation(conversation)}
    end
  end

  @doc "Sends the agent a message. Returns its ID and the cursor its answer follows."
  @spec ask(Wardrik.Scope.t(), map()) :: {:ok, map()} | {:error, Error.t()}
  def ask(scope, input) do
    key = Running.key(input)

    with {:ok, pid} <- Running.awake(scope.wardrik, key) do
      message_id = input["id"] || message_id()
      cursor = Wardrik.EventLog.head(Wardrik.events(scope.wardrik), [key])
      :ok = WardrikCore.ask(pid, text(input), metadata(scope, message_id))
      {:ok, %{"message" => %{"id" => message_id, "cursor" => cursor}}}
    end
  end

  @doc "Approves or rejects the calls the agent waits on, all at once."
  @spec decide(Wardrik.Scope.t(), map()) :: {:ok, map()} | {:error, Error.t()}
  def decide(scope, %{"decisions" => decisions} = input) do
    key = Running.key(input)

    with :ok <- Snapshot.known(scope.wardrik, key),
         {:ok, pid} <- Running.awake(scope.wardrik, key),
         :ok <- waiting_on(pid, key, decisions),
         :ok <- resume(pid, decisions, scope) do
      {:ok, %{"decisions" => Enum.map(decisions, &decided/1)}}
    end
  end

  @doc "Approves one call the agent waits on."
  @spec approve(Wardrik.Scope.t(), map()) :: {:ok, map()} | {:error, Error.t()}
  def approve(scope, %{"interrupt" => interrupt} = input) do
    decision = %{"id" => interrupt, "decision" => "approve", "note" => input["note"]}
    decide(scope, decided_input(input, decision))
  end

  @doc "Rejects one call the agent waits on."
  @spec deny(Wardrik.Scope.t(), map()) :: {:ok, map()} | {:error, Error.t()}
  def deny(scope, %{"interrupt" => interrupt} = input) do
    decision = %{"id" => interrupt, "decision" => "reject", "reason" => input["reason"]}
    decide(scope, decided_input(input, decision))
  end

  defp decided_input(input, decision) do
    input
    |> Map.take(["agent", "conversation"])
    |> Map.put("decisions", [decision])
  end

  @doc "Returns the sign-in URL for a call that waits on a person signing in."
  @spec authorization(Wardrik.Scope.t(), map()) :: {:ok, map()} | {:error, Error.t()}
  def authorization(scope, %{"interrupt" => interrupt} = input) do
    key = Running.key(input)

    with {:ok, pid} <- Running.awake(scope.wardrik, key) do
      case sign_in(WardrikCore.parked(pid), interrupt) do
        %Authorization{url: url} ->
          {:ok, %{"url" => url}}

        nil ->
          {:error,
           Error.new(:not_found, "#{Running.describe(key)} waits on no sign-in for #{interrupt}.")}
      end
    end
  end

  @doc "Cancels what the agent is doing, and drops its queued messages."
  @spec cancel(Wardrik.Scope.t(), map()) :: {:ok, nil} | {:error, Error.t()}
  def cancel(scope, input) do
    key = Running.key(input)

    with :ok <- Snapshot.known(scope.wardrik, key) do
      cancelled(scope, key, Running.whereis(scope.wardrik, key))
      {:ok, nil}
    end
  end

  @doc "Cancels what the agent `key` is doing. Returns whether there was anything."
  @spec cancelled(Wardrik.Scope.t(), Running.key(), pid() | nil) :: boolean()
  def cancelled(_scope, _key, nil), do: false

  def cancelled(scope, key, pid) do
    case WardrikCore.interrupt(pid) do
      :ok ->
        Changes.record(scope, type: "agent.cancelled", agent: key)
        true

      {:error, :idle} ->
        false
    end
  end

  @doc "Returns a page of the agent's log."
  @spec events(Wardrik.Scope.t(), map()) :: {:ok, map()} | {:error, Error.t()}
  def events(scope, input) do
    with {:ok, opts} <- Snapshot.paging(input),
         {:ok, page} <- Snapshot.page(scope, [Running.key(input)], opts) do
      events = Enum.filter(page.events, &Snapshot.typed?(&1, input["types"]))
      {:ok, %{"events" => events, "next" => page.next}}
    end
  end

  @doc "Streams the agent's log as `{event, cursor}`, following new events."
  @spec stream(Wardrik.Scope.t(), map()) :: {:ok, Enumerable.t()} | {:error, Error.t()}
  def stream(scope, input) do
    opts = [after: input["after"], types: input["types"] || :all]

    with {:ok, stream} <- Snapshot.stream(scope, [Running.key(input)], opts),
         do: {:ok, Stream.map(stream, fn {event, cursor} -> {event, Cursor.encode(cursor)} end)}
  end

  @doc "Returns the agent's conversation as a timeline for people to read."
  @spec timeline(Wardrik.Scope.t(), map()) :: {:ok, map()}
  def timeline(scope, input) do
    events = Wardrik.events(scope.wardrik)
    {timeline, cursor} = Wardrik.EventLog.view(events, Running.key(input), Timeline)
    {:ok, %{"items" => JSON.json(Timeline.items(timeline)), "cursor" => Cursor.encode(cursor)}}
  end

  @doc "Returns the agent's runs, with what each did and cost."
  @spec runs(Wardrik.Scope.t(), map()) :: {:ok, map()}
  def runs(scope, input) do
    {runs, cursor} =
      Wardrik.EventLog.view(Wardrik.events(scope.wardrik), Running.key(input), Runs)

    each = Enum.map(Runs.runs(runs), &Map.put(&1, :duration_ms, Runs.duration_ms(&1)))

    {:ok,
     %{
       "runs" => JSON.json(each),
       "totals" => JSON.json(Runs.totals(runs)),
       "cursor" => Cursor.encode(cursor)
     }}
  end

  defp text(%{"content" => content}), do: content

  defp text(%{"parts" => parts}),
    do: Enum.map_join(parts, "\n\n", &Map.get(&1, "content", ""))

  defp message_id do
    random =
      12
      |> :crypto.strong_rand_bytes()
      |> Base.url_encode64(padding: false)

    "msg_" <> random
  end

  defp waiting_on(pid, key, decisions) do
    waiting =
      pid
      |> WardrikCore.parked()
      |> waiting()

    case Enum.reject(decisions, &Map.has_key?(waiting, &1["id"])) do
      [] ->
        :ok

      [%{"id" => call} | _rest] ->
        {:error, Error.new(:conflict, "#{Running.describe(key)} doesn't wait on #{call}.")}
    end
  end

  defp waiting(nil), do: %{}

  defp waiting({:tool_calls, results}),
    do: Map.new(for {call, {:park, reason}} <- results, do: {call.id, reason})

  defp waiting(reason), do: %{"model" => reason}

  defp resume(pid, decisions, scope) do
    answers = Map.new(decisions, &{&1["id"], answer(&1)})

    case WardrikCore.resume(pid, answers, %{by: scope.principal}) do
      :ok -> :ok
      {:error, :not_parked} -> {:error, Error.new(:conflict, "The agent waits on nothing.")}
    end
  end

  defp answer(%{"decision" => "approve", "note" => note}) when is_binary(note),
    do: {:approve, note}

  defp answer(%{"decision" => "approve"}), do: :approve

  defp answer(%{"decision" => "reject"} = decision),
    do: {:deny, decision["reason"] || "Rejected."}

  defp decided(%{"id" => id, "decision" => "approve"}),
    do: %{"id" => id, "decision" => "approved"}

  defp decided(%{"id" => id, "decision" => "reject"}), do: %{"id" => id, "decision" => "rejected"}

  defp sign_in({:tool_calls, parked}, interrupt) do
    Enum.find_value(parked, fn
      {%{id: ^interrupt}, {:park, %Authorization{} = authorization}} -> authorization
      _other -> nil
    end)
  end

  defp sign_in(_parked, _interrupt), do: nil

  defp metadata(%Wardrik.Scope{labels: []} = scope, id), do: %{id: id, principal: scope.principal}

  defp metadata(scope, id),
    do: %{id: id, principal: scope.principal, labels: scope.labels}
end
