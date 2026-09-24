defmodule TarsNotify.Slack.SocketTest do
  use ExUnit.Case, async: true

  alias TarsNotify.Slack.Socket

  test "reads Slack's hello and disconnect" do
    assert Socket.envelope(~s({"type":"hello","num_connections":1})) == :hello
    assert Socket.envelope(~s({"type":"disconnect","reason":"refresh_requested"})) == :disconnect
  end

  test "acknowledges a button press and hands on its payload" do
    frame =
      JSON.encode!(%{
        envelope_id: "e-1",
        type: "interactive",
        payload: %{type: "block_actions", actions: []}
      })

    assert {:ack, "e-1", {:interactive, %{"type" => "block_actions"}}} = Socket.envelope(frame)
  end

  test "acknowledges any other envelope, and ignores what is not one" do
    assert Socket.envelope(~s({"envelope_id":"e-2","type":"events_api","payload":{}})) ==
             {:ack, "e-2", :ignore}

    assert Socket.envelope("not json") == :ignore
  end
end
