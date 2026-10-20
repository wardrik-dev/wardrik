defmodule WardrikHTTP.EventStream do
  @moduledoc """
  The events of `Wardrik.events/2` as server-sent events, until the client
  goes.

      id: eyJhY21lL2FnZW50L3RyaWFnZSI6NDJ9
      data: {"specversion":"1.0","type":"wardrik.interrupt.resolved",…}

      data: {"specversion":"1.0","type":"wardrik.message.delta",…}

  An event that moves the reader's cursor, as its `cursor` says, is
  sent with that cursor as its `id`, so a client's `Last-Event-ID` resumes
  after it. One that leaves it where it was, a delta or tool progress, is
  sent without one. Each event is one `data:` line holding the CloudEvent.

  A process of the stream's own takes the events, handing each over as the
  one before it is sent, so the stream can send a comment every 15 seconds,
  which keeps an idle stream open through proxies and finds a client that
  has gone. It follows them before the response opens, so a client that
  starts from what is written next misses nothing written once it is open.
  A stream whose process is sent an exit, as `WardrikHTTP.Access` sends the
  holders of a revoked token, ends there.
  """

  import Plug.Conn

  @keepalive :timer.seconds(15)

  @doc "Streams `events`, which `Wardrik.events/2` reads after `opts[:after]`, on `conn`."
  @spec serve(Plug.Conn.t(), Enumerable.t(Wardrik.Event.t()), after: String.t()) ::
          Plug.Conn.t()
  def serve(conn, events, opts) do
    stream = self()

    # A suspended reduce opens the events, which follows them, and the
    # taker goes on from there once the stream knows.
    task =
      Task.async(fn ->
        {:suspended, nil, take} =
          Enumerable.reduce(events, {:suspend, nil}, &hand(stream, &1, &2))

        send(stream, {self(), :open})
        take.({:cont, nil})
      end)

    opened(task.pid)

    conn =
      conn
      |> put_resp_content_type("text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      |> send_chunked(200)
      |> follow(task.pid, Keyword.fetch!(opts, :after))

    Task.shutdown(task, :brutal_kill)
    flush(task.pid)
    conn
  end

  defp opened(taker) do
    receive do
      {^taker, :open} -> :ok
      {:EXIT, ^taker, reason} -> exit(reason)
    end
  end

  defp hand(stream, event, nil) do
    send(stream, {self(), event})

    receive do
      :taken -> {:cont, nil}
    end
  end

  defp follow(conn, taker, cursor) do
    receive do
      {^taker, event} ->
        send(taker, :taken)
        sent(conn, frame(event.cloudevent, cursor, event.cursor), taker, event.cursor)

      {:EXIT, _from, _reason} ->
        conn
    after
      @keepalive -> sent(conn, ": keepalive\n\n", taker, cursor)
    end
  end

  defp sent(conn, data, taker, cursor) do
    case chunk(conn, data) do
      {:ok, conn} -> follow(conn, taker, cursor)
      {:error, _closed} -> conn
    end
  end

  defp frame(event, cursor, cursor), do: data(event)
  defp frame(event, _cursor, moved), do: ["id: ", moved, "\n" | data(event)]

  defp data(event), do: ["data: ", JSON.encode!(event), "\n\n"]

  defp flush(taker) do
    receive do
      {^taker, _event} -> :ok
    after
      0 -> :ok
    end
  end
end
