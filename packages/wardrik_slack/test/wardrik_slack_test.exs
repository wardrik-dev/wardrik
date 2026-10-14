defmodule WardrikSlackTest do
  use ExUnit.Case, async: true

  @req_options [plug: {Req.Test, __MODULE__}, retry: false]

  test "is the adapter type: slack names" do
    assert WardrikChannel.discover()["slack"] == WardrikSlack
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

  defp posting do
    test = self()

    Req.Test.stub(__MODULE__, fn conn ->
      send(test, {:slack, conn.request_path, JSON.decode!(Req.Test.raw_body(conn))})
      Req.Test.json(conn, %{ok: true, ts: "9.9"})
    end)

    [token: "xoxb-1", req_options: @req_options]
  end

  test "posts an answer in its thread, saying so where it answered nothing, and clipped to fit" do
    opts = posting()
    nothing = %WardrikChannel.Outbound{room: "C1", thread: "1.1", body: {:reply, "", []}}

    assert {:ok, _posted} = WardrikSlack.deliver(nothing, opts)

    assert_receive {:slack, "/api/chat.postMessage",
                    %{"thread_ts" => "1.1", "text" => "_It answered nothing._"} = posted}

    refute Map.has_key?(posted, "blocks")

    long = %{nothing | body: {:reply, String.duplicate("a", 13_000), []}}
    assert {:ok, _posted} = WardrikSlack.deliver(long, opts)
    assert_receive {:slack, "/api/chat.postMessage", %{"blocks" => [%{"text" => text}]}}
    assert String.length(text) == 12_000
    assert String.ends_with?(text, "…")
  end

  test "posts a notice in a thread, naming the agent the thread is under" do
    opts = posting()
    agent = Wardrik.AgentID.parse!("acme/books/C1-1.1")

    notice = %WardrikNotify.Notice{
      agent: agent,
      kind: :failed,
      at: DateTime.utc_now(),
      reason: "x"
    }

    failed = %WardrikChannel.Outbound{room: "C1", thread: "1.1", body: {:notice, notice}}

    assert {:ok, _posted} = WardrikSlack.deliver(failed, opts)

    assert_receive {:slack, "/api/chat.postMessage",
                    %{"thread_ts" => "1.1", "text" => "acme/books failed"}}

    in_room = %{failed | thread: nil}
    assert {:ok, _posted} = WardrikSlack.deliver(in_room, opts)
    assert_receive {:slack, "/api/chat.postMessage", posted}
    refute Map.has_key?(posted, "thread_ts")
  end
end
