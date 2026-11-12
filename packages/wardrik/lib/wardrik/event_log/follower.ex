defmodule Wardrik.EventLog.Follower do
  @moduledoc false
  # Follows logs for a `Wardrik.Listener` module, one kept event at a time. The listener is any map
  # with `:cursor`: each event comes with the cursor past it.

  alias Wardrik.EventLog.Cursor

  @spec start_link(module(), map(), keyword()) :: {:ok, pid()}
  def start_link(module, listener, opts) do
    events = Keyword.fetch!(opts, :events)
    logs = Keyword.fetch!(opts, :logs)
    # Taken before the task starts, so "new events" means from now.
    started = Wardrik.EventLog.head(events, logs)
    types = Keyword.get(opts, :types, :all)
    Task.start_link(fn -> follow(module, listener, {events, logs, types}, started) end)
  end

  defp follow(module, listener, {events, logs, types}, started) do
    {:ok, stream} =
      Wardrik.EventLog.stream(events, logs,
        after: module.cursor(listener) || started,
        types: types
      )

    Enum.each(stream, fn {event, cursor} ->
      :ok =
        module.handle(Wardrik.Event.from_json(event), %{listener | cursor: Cursor.encode(cursor)})
    end)
  end
end
