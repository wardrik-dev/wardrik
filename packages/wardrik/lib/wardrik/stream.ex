defmodule Wardrik.Stream do
  @moduledoc """
  An agent's log as a lazy `Stream` of `Wardrik.Event.Log.Entry`s, as
  `Wardrik.agent_stream/3` answers it: every entry after a sequence, read
  page by page, then each as the agent writes it, until the process taking
  it stops.

  The process taking it subscribes to the log before it reads, and takes
  only the entries that follow what it read (`Wardrik.Event.Log.Entry.follows?/2`),
  so it sees each once, in order. It unsubscribes once it stops taking, and
  drops what was sent it meanwhile. Where the log was trimmed past where it
  reads, it raises the `:gap` `Wardrik.Error`.
  """

  alias Wardrik.AgentID
  alias Wardrik.Event.Log
  alias Wardrik.Event.Log.Entry

  @page 500

  @doc "The stream of `agent`'s log, kept in `store`, after the sequence `starting_after`."
  @spec new(WardrikStore.t(), AgentID.t(), non_neg_integer()) :: Enumerable.t(Entry.t())
  def new(store, %AgentID{} = agent, starting_after) do
    Stream.resource(
      fn ->
        :ok = Log.subscribe(agent)
        {:reading, starting_after}
      end,
      &next(store, agent, &1),
      fn _state -> stop(agent) end
    )
  end

  defp next(store, agent, {:reading, last}) do
    case Log.read(store, agent, starting_after: last, limit: @page) do
      {:ok, []} -> next(store, agent, {:following, last})
      {:ok, events} -> read(events, last)
      {:gap, oldest} -> raise Wardrik.Error.gap(oldest)
    end
  end

  defp next(_store, _agent, {:following, last}) do
    receive do
      %Entry{} = entry ->
        if Entry.follows?(entry, last),
          do: {[entry], {:following, entry.sequence || last}},
          else: {[], {:following, last}}
    end
  end

  defp read(events, last) do
    entries = Entry.numbered(events, last)
    {entries, {:reading, List.last(entries).sequence}}
  end

  defp stop(agent) do
    Log.unsubscribe(agent)
    flush()
  end

  defp flush do
    receive do
      %Entry{} -> flush()
    after
      0 -> :ok
    end
  end
end
