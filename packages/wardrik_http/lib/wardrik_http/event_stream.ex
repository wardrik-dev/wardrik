defmodule WardrikHTTP.EventStream do
  @moduledoc """
  An agent's log as server-sent events: every event after a sequence, then
  each one as the agent numbers it, until the client goes.

      id: 000000000042
      data: {"specversion":"1.0","type":"wardrik.interrupt.resolved",…}

      data: {"specversion":"1.0","type":"wardrik.message.delta",…}

  A durable event is sent with its sequence as the event's `id`, so a
  client's `Last-Event-ID` resumes after it. A live one, a delta or tool
  progress, is sent without one, so it never moves the client's place. Each
  event is one `data:` line holding the CloudEvent.

  The stream subscribes to the log before it reads, and sends only the
  entries that follow what it read (`Wardrik.Event.Log.Entry.follows?/2`), so
  each event reaches the client once, in order. A comment every 15 seconds
  keeps an idle stream open through proxies, and finds a client that has
  gone. A stream whose process is sent `{:shutdown, :revoked}`, as
  `Wardrik.Access` sends the holders of a revoked token, ends there.
  """

  import Plug.Conn

  alias Wardrik.Event.Log
  alias Wardrik.Event.Log.Entry

  @keepalive :timer.seconds(15)
  @page 500

  @typedoc "Where the stream starts: after a sequence, or after the last event written now."
  @type cursor() :: non_neg_integer() | :head

  @doc """
  Streams `agent_id`'s log after `cursor` on `conn`.

  Answers `{:gap, oldest}` where events after the cursor have been dropped,
  and `:not_found` for `:head` when no agent runs under `agent_id`, in either
  case having sent nothing.
  """
  @spec serve(Plug.Conn.t(), String.t(), cursor()) ::
          Plug.Conn.t() | {:gap, pos_integer()} | :not_found
  def serve(conn, agent_id, cursor) do
    :ok = Log.subscribe(agent_id)

    try do
      with {:ok, starting_after} <- start(agent_id, cursor),
           {:ok, events} <- Log.read(agent_id, starting_after: starting_after, limit: @page) do
        conn
        |> put_resp_content_type("text/event-stream")
        |> put_resp_header("cache-control", "no-cache")
        |> send_chunked(200)
        |> send_events(events, starting_after)
        |> catch_up(agent_id)
        |> follow()
      end
    after
      Log.unsubscribe(agent_id)
      flush()
    end
  end

  defp start(_agent_id, sequence) when is_integer(sequence), do: {:ok, sequence}

  defp start(agent_id, :head) do
    case Wardrik.Agent.snapshot(agent_id) do
      %{sequence: sequence} -> {:ok, sequence}
      {:error, :not_found} -> :not_found
    end
  end

  # Pages of the log after the last event sent, until a read comes back empty.
  defp catch_up({:ok, conn, last}, agent_id) do
    case Log.read(agent_id, starting_after: last, limit: @page) do
      {:ok, [_ | _] = events} -> conn |> send_events(events, last) |> catch_up(agent_id)
      _caught_up -> {:ok, conn, last}
    end
  end

  defp catch_up(closed, _agent_id), do: closed

  defp send_events(conn, events, last) do
    Enum.reduce_while(events, {:ok, conn, last}, fn event, {:ok, conn, _last} ->
      case chunk(conn, frame(event)) do
        {:ok, conn} -> {:cont, {:ok, conn, String.to_integer(event["sequence"])}}
        {:error, _closed} -> {:halt, {:closed, conn}}
      end
    end)
  end

  defp follow({:closed, conn}), do: conn

  defp follow({:ok, conn, last}) do
    receive do
      %Entry{} = entry ->
        if Entry.follows?(entry, last),
          do: send_live(conn, frame(entry.event), entry.sequence || last),
          else: follow({:ok, conn, last})

      {:EXIT, _from, {:shutdown, :revoked}} ->
        conn
    after
      @keepalive -> send_live(conn, ": keepalive\n\n", last)
    end
  end

  defp send_live(conn, data, last) do
    case chunk(conn, data) do
      {:ok, conn} -> follow({:ok, conn, last})
      {:error, _closed} -> conn
    end
  end

  defp frame(%{"sequence" => sequence} = event), do: ["id: ", sequence, "\n" | data(event)]
  defp frame(event), do: data(event)

  defp data(event), do: ["data: ", JSON.encode!(event), "\n\n"]

  defp flush do
    receive do
      %Entry{} -> flush()
    after
      0 -> :ok
    end
  end
end
