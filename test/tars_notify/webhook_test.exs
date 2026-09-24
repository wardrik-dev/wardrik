defmodule TarsNotify.WebhookTest do
  use ExUnit.Case, async: true

  alias TarsNotify.Notice
  alias TarsNotify.Webhook

  @notice %Notice{
    agent: "acme/_/triage",
    kind: :failed,
    at: ~U[2026-09-24 09:30:00Z],
    reason: :timeout
  }

  defp capture(status) do
    test = self()

    Req.Test.stub(TarsNotify.Stub, fn conn ->
      send(test, {:posted, conn.request_path, conn.req_headers, Req.Test.raw_body(conn)})
      conn |> Plug.Conn.put_status(status) |> Req.Test.json(%{})
    end)
  end

  test "posts the notice as JSON, naming the event" do
    capture(200)

    assert :ok = Webhook.deliver(@notice, url: "https://hooks.test/tars", target: :audit)

    assert_receive {:posted, "/tars", headers, body}
    assert {"x-tars-event", "turn_failed"} in headers
    refute List.keyfind(headers, "x-tars-signature", 0)
    assert %{"event" => "turn_failed", "agent" => "acme/_/triage"} = JSON.decode!(body)
  end

  test "signs the body with a secret" do
    capture(200)

    assert :ok = Webhook.deliver(@notice, url: "https://hooks.test/tars", secret: "s3cret")

    assert_receive {:posted, _path, headers, body}
    assert {"x-tars-signature", "sha256=" <> Webhook.hmac("s3cret", body)} in headers
  end

  test "a receiver that refuses the notice is an error" do
    capture(400)

    assert {:error, {:status, 400}} = Webhook.deliver(@notice, url: "https://hooks.test/tars")
  end
end
