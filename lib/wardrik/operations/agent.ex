defmodule Wardrik.Operations.Agent do
  @moduledoc "The operations on one agent: talking to it, answering what it waits on, and reading it."

  alias Wardrik.Error
  alias Wardrik.JSON
  alias Wardrik.Operations.Changes
  alias Wardrik.Operations.Running
  alias Wardrik.Operations.Snapshot
  alias WardrikCore.Authorization
  alias WardrikEvents.Cursor
  alias WardrikEvents.Runs
  alias WardrikEvents.Timeline

  @doc "Reads what the agent is doing now."
  @spec read(Wardrik.Scope.t(), map()) :: {:ok, map()} | {:error, Error.t()}
  def read(scope, %{"agent" => id}) do
    with :ok <- Snapshot.known(scope.wardrik, id) do
      events = Wardrik.events(scope.wardrik)
      activity = WardrikEvents.activity(events, id)

      {:ok,
       %{
         "agent" => %{"id" => id, "name" => Snapshot.name(id)},
         "status" => Snapshot.state(scope.wardrik, id, activity),
         "node" => Snapshot.placed(scope.wardrik, id),
         "pending" => activity["pending"],
         "next_run" => Snapshot.next_run(scope.wardrik, id),
         "spent_today" => Wardrik.Spending.today(scope.wardrik, id),
         "activity" => activity,
         "interrupts" => Snapshot.interrupts(activity),
         "cursor" => WardrikEvents.head(events, [id])
       }}
    end
  end

  @doc "Sends the agent a message, and answers its id with the cursor its answer comes after."
  @spec ask(Wardrik.Scope.t(), map()) :: {:ok, map()} | {:error, Error.t()}
  def ask(scope, %{"agent" => id} = input) do
    with {:ok, pid} <- Running.awake(scope.wardrik, id) do
      message_id = input["id"] || message_id()
      cursor = WardrikEvents.head(Wardrik.events(scope.wardrik), [id])
      :ok = WardrikCore.ask(pid, text(input), metadata(scope, message_id))
      {:ok, %{"message" => %{"id" => message_id, "cursor" => cursor}}}
    end
  end

  @doc "Approves or rejects the calls the agent waits on, together."
  @spec decide(Wardrik.Scope.t(), map()) :: {:ok, map()} | {:error, Error.t()}
  def decide(scope, %{"agent" => id, "decisions" => decisions}) do
    with :ok <- Snapshot.known(scope.wardrik, id),
         {:ok, waiting} <- waiting_on(scope, id, decisions),
         :ok <- approvable(scope, id, waiting, decisions),
         {:ok, pid} <- Running.awake(scope.wardrik, id),
         :ok <- resume(pid, decisions, scope) do
      {:ok, %{"decisions" => Enum.map(decisions, &decided/1)}}
    end
  end

  @doc "Approves one call the agent waits on."
  @spec approve(Wardrik.Scope.t(), map()) :: {:ok, map()} | {:error, Error.t()}
  def approve(scope, %{"agent" => id, "interrupt" => interrupt} = input) do
    decision = %{"id" => interrupt, "decision" => "approve", "note" => input["note"]}
    decide(scope, %{"agent" => id, "decisions" => [decision]})
  end

  @doc "Rejects one call the agent waits on."
  @spec deny(Wardrik.Scope.t(), map()) :: {:ok, map()} | {:error, Error.t()}
  def deny(scope, %{"agent" => id, "interrupt" => interrupt} = input) do
    decision = %{"id" => interrupt, "decision" => "reject", "reason" => input["reason"]}
    decide(scope, %{"agent" => id, "decisions" => [decision]})
  end

  @doc "Returns where a person signs in for a call that waits on it."
  @spec authorization(Wardrik.Scope.t(), map()) :: {:ok, map()} | {:error, Error.t()}
  def authorization(scope, %{"agent" => id, "interrupt" => interrupt}) do
    with {:ok, pid} <- Running.awake(scope.wardrik, id) do
      case sign_in(WardrikCore.parked(pid), interrupt) do
        %Authorization{url: url} -> {:ok, %{"url" => url}}
        nil -> {:error, Error.new(:not_found, "#{id} waits on no sign-in for #{interrupt}.")}
      end
    end
  end

  @doc "Stops what the agent is doing, and drops what's queued behind it."
  @spec cancel(Wardrik.Scope.t(), map()) :: {:ok, nil} | {:error, Error.t()}
  def cancel(scope, %{"agent" => id}) do
    with :ok <- Snapshot.known(scope.wardrik, id) do
      cancelled(scope, id, Running.whereis(scope.wardrik, id))
      {:ok, nil}
    end
  end

  @doc "Stops what the running agent `id` is doing, and records it. Returns whether it was doing anything."
  @spec cancelled(Wardrik.Scope.t(), String.t(), pid() | nil) :: boolean()
  def cancelled(_scope, _id, nil), do: false

  def cancelled(scope, id, pid) do
    case WardrikCore.interrupt(pid) do
      :ok ->
        Changes.record(scope, "agent.cancelled", id)
        true

      {:error, :idle} ->
        false
    end
  end

  @doc "Reads a page of the agent's log."
  @spec events(Wardrik.Scope.t(), map()) :: {:ok, map()} | {:error, Error.t()}
  def events(scope, %{"agent" => id} = input) do
    with {:ok, page} <- Snapshot.page(scope, [id], after: input["after"], limit: input["limit"]) do
      events = Enum.filter(page.events, &Snapshot.typed?(&1, input["types"]))
      {:ok, %{"events" => events, "next" => page.next}}
    end
  end

  @doc "Streams the agent's log, as `{event, cursor}`, reading on and then following."
  @spec stream(Wardrik.Scope.t(), map()) :: {:ok, Enumerable.t()} | {:error, Error.t()}
  def stream(scope, %{"agent" => id} = input) do
    opts = [after: input["after"], types: input["types"] || :all]

    with {:ok, stream} <- Snapshot.stream(scope, [id], opts),
         do: {:ok, Stream.map(stream, fn {event, cursor} -> {event, Cursor.encode(cursor)} end)}
  end

  @doc "Reads the agent's conversation as a person reads it."
  @spec timeline(Wardrik.Scope.t(), map()) :: {:ok, map()}
  def timeline(scope, %{"agent" => id}) do
    {timeline, cursor} = WardrikEvents.view(Wardrik.events(scope.wardrik), id, Timeline)
    {:ok, %{"items" => JSON.json(Timeline.items(timeline)), "cursor" => Cursor.encode(cursor)}}
  end

  @doc "Reads what the agent's runs did and cost."
  @spec runs(Wardrik.Scope.t(), map()) :: {:ok, map()}
  def runs(scope, %{"agent" => id}) do
    {runs, cursor} = WardrikEvents.view(Wardrik.events(scope.wardrik), id, Runs)
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

  defp message_id,
    do: "msg_" <> (12 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false))

  defp waiting_on(scope, id, decisions) do
    waiting =
      scope.wardrik
      |> Wardrik.events()
      |> WardrikEvents.activity(id)
      |> Snapshot.interrupts()
      |> Map.new(&{&1["id"], &1})

    case Enum.reject(decisions, &Map.has_key?(waiting, &1["id"])) do
      [] ->
        {:ok, waiting}

      [%{"id" => call} | _rest] ->
        {:error, Error.new(:conflict, "#{id} doesn't wait on #{call}.")}
    end
  end

  defp approvable(scope, id, waiting, decisions) do
    past_ceiling? =
      Enum.any?(decisions, fn decision ->
        decision["decision"] == "approve" and
          waiting[decision["id"]]["reason"] == "ceiling_approval"
      end)

    if past_ceiling?, do: ceiling_approver(scope, Wardrik.Orgs.org(id)), else: :ok
  end

  defp ceiling_approver(scope, org) do
    resource = Wardrik.Resource.owned(org, "ceiling", nil)

    case Wardrik.Authorizer.authorize(scope, "ceiling.approve", resource) do
      :ok ->
        :ok

      {:error, _refused} ->
        {:error,
         Error.new(
           :forbidden,
           "Approving past #{org}'s ceiling needs ceiling.approve on #{resource}."
         )}
    end
  end

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
