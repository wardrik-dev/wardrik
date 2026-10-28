defmodule Wardrik.HTTP.EventStreamTest do
  use ExUnit.Case, async: false
  use Mimic

  import Wardrik.Test.HTTP

  setup :set_mimic_global
  setup :start_wardrik

  setup context do
    server = start_supervised!({Wardrik.HTTP, wardrik: context.wardrik, port: 0, keepalive: 20})
    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)

    request(context, "PUT", "/v1/agents/acme/triage", %{"model" => "anthropic:claude-haiku-4-5"})
    %{url: "http://localhost:#{port}"}
  end

  test "streams an agent's log, from what's written next", context do
    answers([answer("Hello.")])
    stream = open(context, "/v1/agents/acme/triage/events?types=wardrik.run.completed")

    request(context, "POST", "/v1/agents/acme/triage/messages", %{"content" => "Hi"})

    assert until(stream, "wardrik.run.completed") =~ ~r/^id: \S+\ndata: \{/m
  end

  test "resumes after the Last-Event-ID", context do
    answers([answer("Hello.")])
    :ok = WardrikEvents.subscribe(Wardrik.events(Wardrik.Instance.fetch!(context.wardrik)), ["*"])

    conn = request(context, "POST", "/v1/agents/acme/triage/messages", %{"content" => "Hi"})
    %{"message" => %{"cursor" => cursor}} = body(conn)
    assert_receive {WardrikEvents, _log, %{"type" => "wardrik.run.completed"}}

    stream = open(context, "/v1/events?resources=acme/agent/*", [{"last-event-id", cursor}])
    assert until(stream, "wardrik.run.completed")
  end

  test "keeps a quiet stream open, and ends it once its token is revoked", context do
    stream = open(context, "/v1/events")
    assert until(stream, ": keepalive")

    {:ok, _token} = Wardrik.Tokens.revoke(context.owner, context.token)

    assert ended(stream)
  end

  test "answers a page as JSON without Accept: text/event-stream", context do
    conn = request(context, "GET", "/v1/agents/acme/triage/events")
    assert %{"events" => _events, "next" => _next} = body(conn)
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
