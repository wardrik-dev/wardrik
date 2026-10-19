defmodule WardrikSlackTest do
  use ExUnit.Case, async: true

  @req_options [plug: {Req.Test, __MODULE__}, retry: false]

  test "reads a channel's settings, and says which does not read" do
    assert WardrikSlack.config(%{}) == {:ok, []}
    assert WardrikSlack.config(%{"app_token" => "xapp-1"}) == {:ok, [app_token: "xapp-1"]}

    assert {:ok, options} =
             WardrikSlack.config(%{
               "signing_secret" => "s",
               "client_id" => "1.2",
               "client_secret" => "c"
             })

    assert Enum.sort(options) == [client_id: "1.2", client_secret: "c", signing_secret: "s"]

    assert {:error, ["app_token"], "is the app's app-level token" <> _} =
             WardrikSlack.config(%{"app_token" => 1})

    assert {:error, ["client_secret"], "is required with client_id" <> _} =
             WardrikSlack.config(%{"client_id" => "1.2"})

    assert {:error, ["client_id"], "is required with client_secret" <> _} =
             WardrikSlack.config(%{"client_secret" => "c"})

    assert {:error, ["channel"], "is not a setting" <> _} =
             WardrikSlack.config(%{"channel" => "#ops"})
  end

  test "connects only a channel with an app-level token" do
    assert %{id: {WardrikSlack.Socket, :slack}} =
             WardrikSlack.child_spec(name: :slack, signing_secret: "s")

    assert WardrikSlack.Socket.start_link([]) == :ignore
  end

  test "asks Slack once which bot a workspace's installation posts as" do
    test = self()

    Req.Test.stub(__MODULE__, fn conn ->
      send(test, {:slack, conn.request_path})
      Req.Test.json(conn, %{ok: true, user_id: "UBOT"})
    end)

    installation = %{WardrikSlack.Test.installation() | workspace: "T#{System.unique_integer()}"}

    assert WardrikSlack.bot(installation, @req_options) == {:ok, "UBOT"}
    assert_receive {:slack, "/api/auth.test"}
    assert WardrikSlack.bot(installation, @req_options) == {:ok, "UBOT"}
    refute_receive {:slack, _path}
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

    [req_options: @req_options]
  end

  defp outbound(fields),
    do:
      struct!(WardrikChannel.Outbound, [installation: WardrikSlack.Test.installation()] ++ fields)

  test "posts an answer in its thread, saying so where it answered nothing, and clipped to fit" do
    opts = posting()
    nothing = outbound(room: "C1", thread: "1.1", body: {:reply, "", []})

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

    failed = outbound(room: "C1", thread: "1.1", body: {:notice, notice})

    assert {:ok, _posted} = WardrikSlack.deliver(failed, opts)

    assert_receive {:slack, "/api/chat.postMessage",
                    %{"thread_ts" => "1.1", "text" => "acme/books failed"}}

    in_room = %{failed | thread: nil}
    assert {:ok, _posted} = WardrikSlack.deliver(in_room, opts)
    assert_receive {:slack, "/api/chat.postMessage", posted}
    refute Map.has_key?(posted, "thread_ts")
  end

  test "shows what a thread's agent is doing as the app's status, and clears it" do
    opts = posting()
    working = outbound(room: "C1", thread: "1.1", body: {:status, "running web_search"})

    assert {:ok, _shown} = WardrikSlack.deliver(working, opts)

    assert_receive {:slack, "/api/assistant.threads.setStatus",
                    %{
                      "channel_id" => "C1",
                      "thread_ts" => "1.1",
                      "status" => "is running web_search…"
                    }}

    assert {:ok, _cleared} = WardrikSlack.deliver(%{working | body: {:status, ""}}, opts)
    assert_receive {:slack, "/api/assistant.threads.setStatus", %{"status" => ""}}
  end

  test "takes :eyes: from what a stopped run would have answered, and clears its status" do
    opts = posting()
    stopped = outbound(room: "C1", thread: "1.1", body: {:stopped, ["1.2"]})

    assert {:ok, _cleared} = WardrikSlack.deliver(stopped, opts)

    assert_receive {:slack, "/api/reactions.remove",
                    %{"channel" => "C1", "timestamp" => "1.2", "name" => "eyes"}}

    assert_receive {:slack, "/api/assistant.threads.setStatus",
                    %{"thread_ts" => "1.1", "status" => ""}}

    refute_received {:slack, "/api/reactions.add", _body}
  end

  test "answers why Slack refused a status, such as one rate limited" do
    Req.Test.stub(__MODULE__, fn conn ->
      conn |> Plug.Conn.put_status(429) |> Req.Test.json(%{ok: false, error: "ratelimited"})
    end)

    working = outbound(room: "C1", thread: "1.1", body: {:status, "thinking"})

    assert WardrikSlack.deliver(working, req_options: @req_options) == {:error, "ratelimited"}
  end
end
