defmodule Wardrik.Slack.SocketTest do
  use ExUnit.Case, async: false
  use Mimic

  import Wardrik.Test.Slack

  alias WardrikSlack.Socket
  alias WardrikSlack.Socket.Connection

  setup :set_mimic_global

  defp frame(fields), do: {:text, JSON.encode!(fields)}

  describe "envelopes" do
    test "reads Slack's hello and disconnect" do
      assert Socket.envelope(~s({"type":"hello","num_connections":1})) == :hello

      assert Socket.envelope(~s({"type":"disconnect","reason":"refresh_requested"})) ==
               :disconnect
    end

    test "acknowledges a button press or an event, and hands on what it carries" do
      {:text, pressed} =
        frame(%{envelope_id: "e-1", type: "interactive", payload: %{type: "block_actions"}})

      assert {:ack, "e-1", {:interactive, %{"type" => "block_actions"}}} =
               Socket.envelope(pressed)

      {:text, joined} =
        frame(%{
          envelope_id: "e-2",
          type: "events_api",
          payload: %{event: %{type: "member_joined_channel"}}
        })

      assert {:ack, "e-2", {:event, %{"event" => _event}}} = Socket.envelope(joined)
    end

    test "acknowledges a message once it's handled" do
      {:text, message} =
        frame(%{envelope_id: "e-3", type: "events_api", payload: %{event: %{type: "message"}}})

      assert {:ack_after, "e-3", {:message, %{"event" => %{"type" => "message"}}}} =
               Socket.envelope(message)
    end

    test "acknowledges any other envelope, and leaves what isn't one" do
      assert Socket.envelope(~s({"envelope_id":"e-4","type":"slash_commands"})) ==
               {:ack, "e-4", :ignore}

      assert Socket.envelope("not json") == :ignore
    end
  end

  describe "the connection" do
    test "acknowledges each envelope as Slack expects" do
      assert Connection.handle_frame({:text, ~s({"type":"hello"})}, self()) == {:ok, self()}
      assert_received :hello

      assert Connection.handle_frame({:text, ~s({"type":"disconnect"})}, self()) ==
               {:close, self()}

      assert {:reply, {:text, ~s({"envelope_id":"e-4"})}, _owner} =
               Connection.handle_frame({:text, ~s({"envelope_id":"e-4"})}, self())

      assert {:reply, _ack, _owner} =
               Connection.handle_frame(
                 frame(%{envelope_id: "e-1", type: "interactive", payload: %{}}),
                 self()
               )

      assert_received {:interactive, %{}}

      message =
        frame(%{envelope_id: "e-3", type: "events_api", payload: %{event: %{type: "message"}}})

      assert Connection.handle_frame(message, self()) == {:ok, self()}
      assert_received {:message, %{"event" => _event}, {_connection, "e-3"}}

      assert Connection.handle_frame({:binary, <<0>>}, self()) == {:ok, self()}
      assert Connection.handle_frame({:text, "nope"}, self()) == {:ok, self()}
    end
  end

  describe "Socket Mode" do
    setup :start_wardrik

    @tag slack: [app_token: "xapp-test", signing_secret: nil]
    test "asks Slack where to connect with the app-level token" do
      assert_receive {:slack, "apps.connections.open", _params}, 1_000
    end

    @tag slack: [app_token: "xapp-test", signing_secret: nil]
    test "hands what an envelope carries on in a task", context do
      define(context.owner, "acme/triage", channels: ["slack"])
      socket = start_supervised!({Socket, context.channel})

      callback = %{
        "team_id" => "T1",
        "authorizations" => [%{"user_id" => "UBOT"}],
        "event" => %{"type" => "member_joined_channel", "user" => "UBOT", "channel" => "C1"}
      }

      send(socket, {:event, callback})
      assert_receive {:slack, "chat.postMessage", %{"text" => ":wave:" <> _rest}}, 1_000

      send(socket, {:interactive, %{"team" => %{"id" => "T1"}, "actions" => []}})
      send(socket, :hello)
      send(socket, :unknown)
      assert :sys.get_state(socket).backoff == 1_000
    end
  end
end
