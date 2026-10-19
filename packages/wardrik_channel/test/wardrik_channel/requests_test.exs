defmodule WardrikChannel.RequestsTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias WardrikChannel.Installations
  alias WardrikChannel.Requests

  defp request(method, path, body \\ "") do
    settings = [
      channels: [chat: {WardrikChannel.Test.Adapter, test: self()}],
      installations: Installations.Config.new([])
    ]

    method
    |> conn(path, body)
    |> Plug.Conn.put_private(:wardrik_host, Wardrik.Host.new(store: Wardrik.Test.store()))
    |> Requests.call(Requests.init(settings))
  end

  test "hands a channel what its medium sent, as it was sent, and sends back its answer" do
    conn = request(:post, "/v1/channels/chat/events?retry=1", ~s({"a": 1}))

    assert conn.status == 200
    assert JSON.decode!(conn.resp_body) == %{"path" => ["events"], "body" => ~s({"a": 1})}
    assert_received {:request, %{method: "POST", query: %{"retry" => "1"}}, opts}
    assert opts[:context].host == conn.private.wardrik_host
  end

  test "answers 404 where no channel of the name takes requests, or for what is not a POST" do
    assert %{status: 404, resp_body: body} = request(:post, "/v1/channels/elsewhere/events")
    assert JSON.decode!(body)["error"]["message"] == "No channel elsewhere takes requests here."

    assert %{status: 404, resp_body: body} = request(:get, "/v1/channels/chat/events")
    assert JSON.decode!(body)["error"]["message"] == "No such route: GET /v1/channels/chat/events"
  end

  test "reads at most 1 MB of a request" do
    conn = request(:post, "/v1/channels/chat/events", String.duplicate("a", 1_048_577))

    assert conn.status == 413
    assert JSON.decode!(conn.resp_body)["error"]["type"] == "invalid_request"
  end
end
