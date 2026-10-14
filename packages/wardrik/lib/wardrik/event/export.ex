defmodule Wardrik.Event.Export do
  @moduledoc """
  Every log, read on from where a named reader last got to: the audit, and
  each agent's, a forgotten agent's included.

      {:ok, page} = Wardrik.Event.Export.read(store, "siem")
      :ok = ship(page.events)
      :ok = Wardrik.Event.Export.advance(store, "siem", page.next)

  ## The cursor

  A reader is a name, and its cursor is the last sequence it has taken of
  each log, kept in the store the logs are, which every function is handed
  first. It carries on from there on any node, and after
  any restart.

  `read/3` answers a page after the cursor and leaves the cursor where it
  is. `advance/3` moves it to a page's `next` once the reader holds what the
  page held safely, so a page read again before then answers the same events,
  and each event reaches the reader at least once. `next` names only the logs
  the page read, so it stays small however many logs there are.

  A page takes the logs in the order `Wardrik.Event.Log.logs/1` lists them,
  each from its cursor, until it holds `:limit` events. Each event is the
  CloudEvent its log holds: its `source` names the log, and its `sequence`
  its place there.

  ## Gaps

  A log trimmed past the cursor is read from its oldest event, and the page
  says so in `gaps`: the log, the sequence the cursor was at, and the oldest
  the log still held.
  """

  alias Wardrik.AgentID
  alias Wardrik.Event.Log

  @ns :event_exports

  @default_limit 500

  @enforce_keys [:events, :next]
  defstruct [:events, :next, gaps: []]

  @typedoc "A gap: the log, the sequence the cursor was at, and the oldest the log held."
  @type gap() :: %{log: Log.log(), after: non_neg_integer(), oldest: pos_integer()}

  @typedoc """
  A page: its events, oldest first within each log, the `next` that
  `advance/3` takes to move the cursor past them, and the gaps it met.
  """
  @type t() :: %__MODULE__{events: [map()], next: String.t(), gaps: [gap()]}

  @doc """
  The page after the cursor of `name`, which stays where it is.

  Options:

    * `:limit` - how many events to answer at most, #{@default_limit} by default
    * `:logs` - which logs to read, as a function given each one; every log
      by default
  """
  @spec read(WardrikStore.t(), String.t(), keyword()) :: {:ok, t()}
  def read(store, name, opts \\ []) when is_binary(name) do
    cursor = cursor(store, name)
    reads? = Keyword.get(opts, :logs, fn _log -> true end)

    start = {Keyword.get(opts, :limit, @default_limit), [], %{}, []}

    page =
      store
      |> Log.logs()
      |> Enum.filter(reads?)
      |> Enum.reduce_while(start, &page(store, &1, &2, cursor))

    {_left, events, next, gaps} = page

    {:ok,
     %__MODULE__{
       events: events |> Enum.reverse() |> Enum.concat(),
       next: encode(next),
       gaps: Enum.reverse(gaps)
     }}
  end

  # The page with what `log` holds after the cursor added, as the events
  # left to take, the events taken, the positions after them, and the gaps.
  defp page(store, log, page, cursor) do
    case take(store, log, Map.get(cursor, text(log), 0), elem(page, 0)) do
      :none -> {:cont, page}
      taken -> taken |> added(log, page) |> continue()
    end
  end

  # What a log holds after `cursor`: its events, where a cursor past them
  # is, and the gap it met, or `:none` where it holds nothing more.
  defp take(store, log, cursor, limit) do
    case Log.read(store, log, starting_after: cursor, limit: limit, consistent: false) do
      {:ok, []} ->
        :none

      {:ok, events} ->
        {events, cursor + length(events), nil}

      {:gap, oldest} ->
        {:ok, events} =
          Log.read(store, log, starting_after: oldest - 1, limit: limit, consistent: false)

        {events, oldest - 1 + length(events), %{log: log, after: cursor, oldest: oldest}}
    end
  end

  defp added({taken, to, gap}, log, {left, events, next, gaps}) do
    {left - length(taken), [taken | events], Map.put(next, text(log), to),
     if(gap, do: [gap | gaps], else: gaps)}
  end

  defp continue({0, _events, _next, _gaps} = page), do: {:halt, page}
  defp continue(page), do: {:cont, page}

  @doc """
  Moves the cursor of `name` to `next`, a page's, for each log the page read,
  never back. `{:error, :invalid}` where `next` is not one `read/3` answered.
  """
  @spec advance(WardrikStore.t(), String.t(), String.t()) :: :ok | {:error, :invalid | term()}
  def advance(store, name, next) when is_binary(name) and is_binary(next) do
    with {:ok, positions} <- decode(next), do: moved(store, name, positions)
  end

  defp moved(store, name, positions) do
    {cursor, vsn} = lookup(store, name)
    cursor = Map.merge(cursor, positions, fn _log, at, to -> max(at, to) end)

    case WardrikStore.put(store, @ns, name, cursor, if_vsn: vsn) do
      {:ok, _vsn} -> :ok
      {:error, :conflict} -> moved(store, name, positions)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Deletes the cursor of `name`, so its next read starts at the beginning."
  @spec forget(WardrikStore.t(), String.t()) :: :ok | {:error, term()}
  def forget(store, name) when is_binary(name) do
    case lookup(store, name) do
      {_cursor, nil} -> :ok
      {_cursor, vsn} -> WardrikStore.delete(store, @ns, name, if_vsn: vsn)
    end
  end

  @doc "The cursor of `name`: the last sequence taken of each log, by its text."
  @spec cursor(WardrikStore.t(), String.t()) :: %{String.t() => non_neg_integer()}
  def cursor(store, name) when is_binary(name), do: store |> lookup(name) |> elem(0)

  defp lookup(store, name) do
    case WardrikStore.lookup(store, @ns, name) do
      {cursor, vsn} -> {cursor, vsn}
      nil -> {%{}, nil}
    end
  end

  # A log as a cursor names it: "audit", or an agent's ID.
  defp text(:audit), do: "audit"
  defp text(%AgentID{} = id), do: to_string(id)

  defp encode(positions), do: positions |> JSON.encode!() |> Base.url_encode64(padding: false)

  defp decode(next) do
    with {:ok, json} <- Base.url_decode64(next, padding: false),
         {:ok, positions} when is_map(positions) <- JSON.decode(json),
         true <- Enum.all?(positions, &position?/1) do
      {:ok, positions}
    else
      _other -> {:error, :invalid}
    end
  end

  defp position?({"audit", to}), do: is_integer(to) and to >= 0

  defp position?({log, to}),
    do: is_integer(to) and to >= 0 and match?({:ok, _id}, AgentID.parse(log))
end
