defmodule WardrikSlack.ConnectionTest do
  use ExUnit.Case, async: false

  alias WardrikSlack.Socket
  alias WardrikSlack.Socket.Connection

  @state %{
    token: "xapp-test",
    answer: [token: "xoxb-test", req_options: [plug: {Req.Test, WardrikSlack.Stub}]],
    connection: nil,
    backoff: 1_000
  }

  describe "the connection's frames" do
    test "says hello to its owner, and closes on Slack's disconnect" do
      assert {:ok, owner} = Connection.handle_frame({:text, ~s({"type":"hello"})}, self())
      assert owner == self()
      assert_received :hello

      assert {:close, _owner} =
               Connection.handle_frame({:text, ~s({"type":"disconnect"})}, self())
    end

    test "acknowledges an envelope, and hands on only a button press" do
      press = JSON.encode!(%{envelope_id: "e-1", type: "interactive", payload: %{"a" => 1}})

      assert {:reply, {:text, ack}, _owner} = Connection.handle_frame({:text, press}, self())
      assert JSON.decode!(ack) == %{"envelope_id" => "e-1"}
      assert_received {:interactive, %{"a" => 1}}

      other = JSON.encode!(%{envelope_id: "e-2", type: "events_api", payload: %{}})
      assert {:reply, {:text, _ack}, _owner} = Connection.handle_frame({:text, other}, self())
      refute_received {:interactive, _payload}
    end

    test "hands on a message unacknowledged, and acknowledges it when asked" do
      message =
        JSON.encode!(%{
          envelope_id: "e-3",
          type: "events_api",
          payload: %{event: %{type: "message"}}
        })

      assert {:ok, _owner} = Connection.handle_frame({:text, message}, self())
      assert_received {:message, %{"type" => "message"}, {connection, "e-3"}}
      assert connection == self()

      test = self()

      fake =
        spawn(fn ->
          receive do
            {:"$websockex_send", from, frame} ->
              send(test, {:sent, frame})
              :gen.reply(from, :ok)
          end
        end)

      assert Connection.ack(fake, "e-3") == :ok
      assert_receive {:sent, {:text, ack}}
      assert JSON.decode!(ack) == %{"envelope_id" => "e-3"}
    end

    test "passes over anything else" do
      assert {:ok, _owner} = Connection.handle_frame({:text, "not json"}, self())
      assert {:ok, _owner} = Connection.handle_frame({:binary, <<1>>}, self())
    end
  end

  describe "the socket" do
    test "connects as it starts, and tries again, waiting longer each time, when Slack will not open a connection" do
      Req.Test.stub(WardrikSlack.Stub, &Req.Test.json(&1, %{ok: false, error: "invalid_auth"}))

      assert {:noreply, %{backoff: 2_000}} = Socket.handle_continue(:connect, @state)
      assert {:noreply, %{backoff: 2_000}} = Socket.handle_info(:connect, @state)

      assert {:noreply, %{backoff: 60_000}} =
               Socket.handle_info(:connect, %{@state | backoff: 60_000})
    end

    test "finds the bot it posts as once, and tries again when the connection cannot be reached" do
      test = self()

      Req.Test.stub(WardrikSlack.Stub, fn conn ->
        send(test, {:asked, conn.request_path})

        case conn.request_path do
          "/api/auth.test" -> Req.Test.json(conn, %{ok: true, user_id: "UBOT", team_id: "T1"})
          _open -> Req.Test.json(conn, %{ok: true, url: "ws://127.0.0.1:1/"})
        end
      end)

      assert {:noreply, %{connection: nil, backoff: 2_000} = state} =
               Socket.handle_info(:connect, @state)

      assert state.answer[:bot] == "UBOT"
      assert state.answer[:team] == "T1"
      assert_received {:asked, "/api/auth.test"}

      assert {:noreply, _state} = Socket.handle_info(:connect, state)
      refute_received {:asked, "/api/auth.test"}
    end

    test "starts over after a hello, and reconnects when its connection ends" do
      assert {:noreply, %{backoff: 1_000}} =
               Socket.handle_info(:hello, %{@state | backoff: 8_000})

      connection = self()

      assert {:noreply, %{connection: nil, backoff: 2_000}} =
               Socket.handle_info({:EXIT, connection, :normal}, %{@state | connection: connection})

      assert {:noreply, @state} =
               Socket.handle_info({:EXIT, spawn(fn -> :ok end), :normal}, @state)
    end

    test "answers a button press, and acts on an event, each in a task of its own" do
      start_supervised!({Task.Supervisor, name: WardrikChannel.tasks()})

      assert {:noreply, @state} = Socket.handle_info({:interactive, %{"actions" => []}}, @state)

      room_press = %{"actions" => [%{"action_id" => "wardrik_room_answers", "value" => "x"}]}
      assert {:noreply, @state} = Socket.handle_info({:interactive, room_press}, @state)

      assert {:noreply, @state} =
               Socket.handle_info({:event, %{"type" => "reaction_added"}}, @state)

      test = self()

      fake =
        spawn(fn ->
          receive do
            {:"$websockex_send", from, frame} ->
              send(test, {:sent, frame})
              :gen.reply(from, :ok)
          end
        end)

      assert {:noreply, @state} =
               Socket.handle_info({:message, %{"type" => "message"}, {fake, "e-5"}}, @state)

      assert_receive {:sent, {:text, ~s({"envelope_id":"e-5"})}}
    end
  end
end
