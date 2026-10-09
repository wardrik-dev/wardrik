defmodule WardrikSlackTest do
  use ExUnit.Case, async: true

  @req_options [plug: {Req.Test, __MODULE__}, retry: false]

  test "is the adapter type: slack names" do
    assert WardrikChannel.adapter("slack") == {:ok, WardrikSlack}
  end

  test "reads a channel's tokens, and says which does not read" do
    assert WardrikSlack.config(%{"token" => "xoxb-1"}) == {:ok, [token: "xoxb-1"]}

    assert WardrikSlack.config(%{"token" => "xoxb-1", "app_token" => "xapp-1"}) ==
             {:ok, [token: "xoxb-1", app_token: "xapp-1"]}

    assert {:error, ["token"], "is required" <> _} = WardrikSlack.config(%{})

    assert {:error, ["app_token"], _why} =
             WardrikSlack.config(%{"token" => "x", "app_token" => 1})

    assert {:error, ["channel"], "is not a setting" <> _} =
             WardrikSlack.config(%{"token" => "x", "channel" => "#ops"})
  end

  test "connects only a channel with an app-level token" do
    assert %{id: {WardrikSlack.Socket, :slack}} =
             WardrikSlack.child_spec(name: :slack, token: "x")

    assert WardrikSlack.Socket.start_link(name: :slack, token: "x") == :ignore
  end

  test "answers Slack's reply, or why the call failed" do
    Req.Test.stub(__MODULE__, &Req.Test.json(&1, %{ok: true, ts: "1696.1234"}))

    assert {:ok, %{"ts" => "1696.1234"}} =
             WardrikSlack.post("chat.postMessage", "x", %{}, @req_options)

    Req.Test.stub(__MODULE__, &Req.Test.json(&1, %{ok: false, error: "channel_not_found"}))

    assert {:error, "channel_not_found"} =
             WardrikSlack.post("chat.postMessage", "x", %{}, @req_options)

    Req.Test.stub(__MODULE__, &Plug.Conn.send_resp(&1, 502, "bad gateway"))

    assert {:error, {:status, 502}} =
             WardrikSlack.post("chat.postMessage", "x", %{}, @req_options)

    Req.Test.stub(__MODULE__, &Req.Test.transport_error(&1, :econnrefused))

    assert {:error, %Req.TransportError{reason: :econnrefused}} =
             WardrikSlack.post("chat.postMessage", "x", %{}, @req_options)
  end
end
