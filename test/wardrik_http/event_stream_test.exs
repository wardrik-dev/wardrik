defmodule WardrikHTTP.EventStreamTest do
  use ExUnit.Case, async: true

  import WardrikHTTP.Test

  alias WardrikTesting.Server

  setup context do
    name = :"server #{context.test}"
    :ok = start(name, ["wrk_good"])

    http =
      start_supervised!(
        {WardrikHTTP,
         server: {Server, name},
         authenticator: {WardrikHTTP.Test.Authenticator, []},
         port: 0,
         keepalive: 20},
        id: :http
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(http)
    %{name: name, secret: "wrk_good", url: "http://localhost:#{port}"}
  end

  test "streams what its server streams, each event with its cursor as its id", context do
    stream = open(context, "/v1/agents/acme/triage/events?types=wardrik.run.completed")

    assert_receive {:streamed, "agent.events",
                    %{"agent" => "acme/triage", "types" => ["wardrik.run.completed"]}}

    assert until(stream, "wardrik.run.completed") =~ ~r/^id: cursor-1\ndata: \{/m
  end

  test "resumes after the Last-Event-ID", context do
    stream = open(context, "/v1/events", [{"last-event-id", "cursor-0"}])
    assert_receive {:streamed, "events.list", %{"after" => "cursor-0"}}
    assert until(stream, "wardrik.run.completed")
  end

  test "keeps a quiet stream open, and ends it once it no longer authenticates", context do
    stream = open(context, "/v1/events")
    assert until(stream, ": keepalive")

    WardrikHTTP.Test.Authenticator.revoke(context.name, context.secret)
    assert ended(stream)
  end

  test "answers a page as JSON without Accept: text/event-stream", context do
    conn = request(context, "GET", "/v1/agents/acme/triage/events")
    assert %{"events" => _events} = body(conn)
    assert_received {:ran, "agent.events", %{"agent" => "acme/triage"}}
  end

  test "answers why it can't stream as the protocol's error", context do
    stream =
      Req.get!(context.url <> "/v1/events?after=nope", headers: headers(context), retry: false)

    assert {stream.status, stream.body["error"]["type"]} == {400, "invalid_request"}
  end

  defp open(context, path, headers \\ []) do
    Req.get!(context.url <> path, headers: headers(context) ++ headers, into: :self, retry: false)
  end

  defp headers(context),
    do: [{"authorization", "Bearer " <> context.secret}, {"accept", "text/event-stream"}]

  defp until(stream, text, read \\ "") do
    case String.contains?(read, text) do
      true -> read
      false -> until(stream, text, read <> next(stream))
    end
  end

  defp ended(stream) do
    case parsed(stream) do
      [:done] -> true
      _data -> ended(stream)
    end
  end

  defp next(stream) do
    case parsed(stream) do
      [data: data] -> data
      [:done] -> flunk("The stream ended.")
    end
  end

  defp parsed(stream) do
    receive do
      message ->
        case Req.parse_message(stream, message) do
          {:ok, parts} -> parts
          :unknown -> parsed(stream)
        end
    after
      1_000 -> flunk("The stream sent nothing.")
    end
  end
end
