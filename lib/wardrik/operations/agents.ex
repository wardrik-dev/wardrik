defmodule Wardrik.Operations.Agents do
  @moduledoc "The operations over the agents resource patterns cover: listing them, and their events."

  alias Wardrik.Operations.Snapshot
  alias Wardrik.Operations.Visible
  alias Wardrik.Scope
  alias WardrikEvents.Cursor

  @doc "Lists the agents."
  @spec list(Scope.t(), map()) :: {:ok, map()}
  def list(scope, input) do
    agents =
      for id <- Visible.agents(scope, input) do
        activity = WardrikEvents.activity(Wardrik.events(scope.wardrik), id)

        %{
          "id" => id,
          "name" => Snapshot.name(id),
          "status" => Snapshot.status(activity),
          "pending" => activity["pending"]
        }
      end

    {:ok, %{"agents" => agents}}
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

  @doc "Reads a page of the agents' events."
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

  @doc "Streams the agents' events, as `{event, cursor}`, reading on and then following."
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
