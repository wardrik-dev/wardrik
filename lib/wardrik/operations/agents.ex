defmodule Wardrik.Operations.Agents do
  @moduledoc "Operations over the agents that resource patterns cover: listing them and their events."

  alias Wardrik.Operations.Agent
  alias Wardrik.Operations.Changes
  alias Wardrik.Operations.Lifecycle
  alias Wardrik.Operations.Running
  alias Wardrik.Operations.Snapshot
  alias Wardrik.Operations.Visible
  alias Wardrik.Scope
  alias WardrikEvents.Cursor

  @doc "Lists the agents."
  @spec list(Scope.t(), map()) :: {:ok, map()}
  def list(scope, input) do
    agents = Enum.map(Visible.agents(scope, input), &Snapshot.summary(scope.wardrik, &1))
    {:ok, %{"agents" => agents}}
  end

  @doc "Cancels what each agent is doing. Returns those that were cancelled."
  @spec cancel(Scope.t(), map()) :: {:ok, map()}
  def cancel(scope, input) do
    cancelled =
      Enum.filter(Visible.agents(scope, input), fn id ->
        Agent.cancelled(scope, id, Running.whereis(scope.wardrik, id))
      end)

    {:ok, %{"cancelled" => cancelled}}
  end

  @doc """
  Forgets each agent. Returns those forgotten, those kept because they're declared, and those
  that failed, with why.
  """
  @spec forget(Scope.t(), map()) :: {:ok, map()}
  def forget(scope, input) do
    {kept, covered} =
      scope
      |> Visible.agents(input)
      |> Enum.split_with(&Wardrik.Declarations.declared?(scope.wardrik, &1))

    {forgotten, failed} =
      covered
      |> Enum.map(&{&1, Lifecycle.forgotten(scope.wardrik, &1)})
      |> Enum.split_with(fn {_id, outcome} -> outcome == :ok end)

    Enum.each(forgotten, fn {id, :ok} -> Changes.record(scope, "agent.forgotten", id) end)

    {:ok,
     %{
       "forgotten" => Enum.map(forgotten, fn {id, :ok} -> id end),
       "kept" => Enum.map(kept, &%{"id" => &1, "why" => "declared by a file"}),
       "failed" =>
         Enum.map(failed, fn {id, {:error, error}} -> %{"id" => id, "why" => error.message} end)
     }}
  end

  @doc "Lists the calls the agents wait on a person for."
  @spec interrupts(Scope.t(), map()) :: {:ok, map()}
  def interrupts(scope, input) do
    interrupts =
      for id <- Visible.agents(scope, input),
          interrupt <-
            Snapshot.interrupts(WardrikEvents.activity(Wardrik.events(scope.wardrik), id)),
          do: %{"agent" => %{"id" => id}, "interrupt" => interrupt}

    {:ok, %{"interrupts" => interrupts}}
  end

  @doc "Returns a page of the agents' events."
  @spec events(Scope.t(), map()) :: {:ok, map()} | {:error, Wardrik.Error.t()}
  def events(scope, input) do
    opts = [after: input["after"], limit: input["limit"]]

    with {:ok, page} <- Snapshot.page(scope, Visible.logs(input), opts) do
      events =
        Enum.filter(page.events, fn event ->
          Visible.visible?(scope, Visible.patterns(input), Visible.agent_id(event)) and
            Snapshot.typed?(event, input["types"])
        end)

      {:ok, %{"events" => events, "next" => visible_cursor(scope, input, page.next)}}
    end
  end

  @doc "Returns the cursor at the end of the agents' logs."
  @spec head(Scope.t(), map()) :: {:ok, map()}
  def head(scope, input) do
    cursor = WardrikEvents.head(Wardrik.events(scope.wardrik), Visible.logs(input))
    {:ok, %{"cursor" => visible_cursor(scope, input, cursor)}}
  end

  @doc "Streams the agents' events as `{event, cursor}`. Reads what's there, then follows new events."
  @spec stream(Scope.t(), map()) :: {:ok, Enumerable.t()} | {:error, Wardrik.Error.t()}
  def stream(scope, input) do
    patterns = Visible.patterns(input)
    visible? = &Visible.visible?(scope, patterns, &1)
    opts = [after: input["after"], types: input["types"] || :all]

    with {:ok, stream} <- Snapshot.stream(scope, Visible.logs(input), opts) do
      {:ok,
       stream
       |> Stream.filter(fn {event, _cursor} -> visible?.(Visible.agent_id(event)) end)
       |> Stream.map(fn {event, cursor} -> {event, encoded(cursor, visible?)} end)}
    end
  end

  defp visible_cursor(scope, input, text) do
    {:ok, cursor} = Cursor.decode(text)
    encoded(cursor, &Visible.visible?(scope, Visible.patterns(input), &1))
  end

  defp encoded(cursor, visible?),
    do: cursor |> Map.filter(fn {log, _sequence} -> visible?.(log) end) |> Cursor.encode()
end
