defmodule MyApp.Agents.Runs do
  @moduledoc """
  Keeps when each run of every agent starts and ends in this app's own
  tables, with the cursor past it in the same transaction, so a restart
  carries on where it stopped.
  """

  use Wardrik.Listener

  import Ecto.Query

  alias MyApp.Repo
  alias Wardrik.Event.Log.Entry

  @doc "The child that runs it, after Wardrik, on `wardrik`."
  def child_spec(wardrik) do
    super(
      host: wardrik,
      principal: Wardrik.Principal.deployment(),
      resources: [Wardrik.Resource.parse!("*/agent/*")],
      types: ~w(wardrik.run.started wardrik.run.completed wardrik.run.failed)
    )
  end

  # The log was trimmed past the cursor, so the events between are gone:
  # keep what the agent says of itself now in their place.
  @impl true
  def handle(%Entry{event: %{"type" => "wardrik.events.dropped"} = event} = entry, listener) do
    {:ok, snapshot} = Wardrik.agent_read(listener.scope, entry.log)
    keep(entry, %{event | "data" => %{"status" => to_string(snapshot.status.state)}}, listener.cursor)
  end

  def handle(%Entry{event: event} = entry, listener), do: keep(entry, event, listener.cursor)

  # The first start reads from the head of every log, kept at once so a
  # restart before the first event misses nothing.
  @impl true
  def cursor(listener) do
    case Repo.one(from(c in "wardrik_cursors", where: c.name == "runs", select: c.cursor)) do
      nil -> save!(Wardrik.events_head!(listener.scope, Keyword.take(listener.options, [:resources])))
      cursor -> cursor
    end
  end

  # An event comes again after a restart that cut its transaction short; the
  # id it is kept under drops the repeat.
  defp keep(entry, event, cursor) do
    {:ok, at, 0} = DateTime.from_iso8601(event["time"])
    row = %{id: event["id"], agent: to_string(entry.log), type: event["type"], data: event["data"], at: at}

    {:ok, _cursor} =
      Repo.transaction(fn ->
        Repo.insert_all("agent_events", [row], on_conflict: :nothing)
        save!(cursor)
      end)

    :ok
  end

  defp save!(cursor) do
    Repo.insert_all("wardrik_cursors", [%{name: "runs", cursor: cursor}],
      on_conflict: {:replace, [:cursor]},
      conflict_target: :name
    )

    cursor
  end
end
