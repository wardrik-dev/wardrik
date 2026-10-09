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

    test "tries again when the connection it was given cannot be reached" do
      Req.Test.stub(WardrikSlack.Stub, &Req.Test.json(&1, %{ok: true, url: "ws://127.0.0.1:1/"}))

      assert {:noreply, %{connection: nil, backoff: 2_000}} = Socket.handle_info(:connect, @state)
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

    test "answers a button press in a task of its own" do
      start_supervised!({Task.Supervisor, name: WardrikChannel.tasks()})

      assert {:noreply, @state} = Socket.handle_info({:interactive, %{"actions" => []}}, @state)
    end
  end
end
