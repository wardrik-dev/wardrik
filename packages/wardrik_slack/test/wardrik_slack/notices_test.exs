defmodule WardrikSlack.NoticesTest do
  use ExUnit.Case, async: false

  import Wardrik.AgentID, only: [sigil_A: 2]

  alias WardrikChannel.Outbound
  alias WardrikNotify.Notice

  @req_options [plug: {Req.Test, WardrikSlack.Stub}]
  @channel [token: "xoxb-test", app_token: "xapp-test", req_options: @req_options]

  setup do
    test = self()

    Req.Test.stub(WardrikSlack.Stub, fn conn ->
      send(test, {:slack, conn.host, conn.request_path, JSON.decode!(Req.Test.raw_body(conn))})
      Req.Test.json(conn, %{ok: true})
    end)

    :ok
  end

  # Posts `notice` in #ops, as a channel with `channel`'s options.
  defp post(notice, channel \\ @channel, approvers \\ []),
    do:
      WardrikSlack.deliver(
        %Outbound{room: "#ops", body: {:notice, notice}, approvers: approvers},
        channel
      )

  defp parked_notice do
    %Notice{
      agent: ~A"acme/triage",
      kind: :parked,
      at: ~U[2026-09-24 09:30:00Z],
      calls: [
        %{id: "call_1", name: "deploy", arguments: %{"env" => "prod"}, prompt: "This ships."}
      ]
    }
  end

  describe "deliver/2" do
    test "posts a parked turn with buttons on each call" do
      assert {:ok, _reply} = post(parked_notice())

      assert_receive {:slack, "slack.com", "/api/chat.postMessage", message}
      assert message["channel"] == "#ops"
      assert message["text"] == "acme/triage is waiting on you: deploy"

      assert %{"elements" => [approve, deny]} =
               Enum.find(message["blocks"], &(&1["block_id"] == "wardrik:call_1"))

      assert approve["action_id"] == "wardrik_approve"
      assert deny["action_id"] == "wardrik_deny"

      assert JSON.decode!(approve["value"]) == %{
               "a" => "acme/triage",
               "c" => "call_1",
               "n" => "deploy"
             }
    end

    test "gives each call a box for why it is denied, above its buttons" do
      assert {:ok, _reply} = post(parked_notice())
      assert_receive {:slack, "slack.com", "/api/chat.postMessage", message}

      ids = Enum.map(message["blocks"], & &1["block_id"])

      assert Enum.find_index(ids, &(&1 == "wardrik-note:call_1")) ==
               Enum.find_index(ids, &(&1 == "wardrik:call_1")) - 1

      box = Enum.find(message["blocks"], &(&1["block_id"] == "wardrik-note:call_1"))

      assert %{"type" => "input", "optional" => true, "element" => %{"action_id" => "note"}} =
               box
    end

    test "says what the turn had read, which may be what asked for the call" do
      [call] = parked_notice().calls
      notice = %{parked_notice() | calls: [Map.put(call, :labels, ["outside", "books"])]}

      assert {:ok, _reply} = post(notice)
      assert_receive {:slack, _host, "/api/chat.postMessage", message}

      assert JSON.encode!(message["blocks"]) =~
               "It has read content from outside and content labelled books"
    end

    test "says how to answer from a shell when there is no app token" do
      assert {:ok, _reply} = post(parked_notice(), token: "xoxb-test", req_options: @req_options)

      assert_receive {:slack, _host, "/api/chat.postMessage", message}
      refute Enum.any?(message["blocks"], &(&1["type"] in ["actions", "input"]))
      assert JSON.encode!(message["blocks"]) =~ "wardrik approve acme/triage call_1"
    end

    test "posts what a turn failed of, and what one answered" do
      failed = %{parked_notice() | kind: :failed, calls: [], reason: :timeout}
      assert {:ok, _reply} = post(failed)

      assert_receive {:slack, _host, _path,
                      %{"text" => "acme/triage failed", "blocks" => [block]}}

      assert block["text"]["text"] =~ ":timeout"

      answered = %{parked_notice() | kind: :finished, calls: [], text: "Two incidents need you."}
      assert {:ok, _reply} = post(answered)

      assert_receive {:slack, _host, _path,
                      %{"text" => "acme/triage answered", "blocks" => [_title, body]}}

      assert body == %{"type" => "markdown", "text" => "Two incidents need you."}
    end

    test "reports what Slack refused" do
      Req.Test.stub(
        WardrikSlack.Stub,
        &Req.Test.json(&1, %{ok: false, error: "channel_not_found"})
      )

      assert {:error, "channel_not_found"} =
               post(parked_notice())
    end
  end

  describe "a call waiting on a person to connect an account" do
    defp connecting_notice do
      %Notice{
        agent: ~A"acme/triage",
        kind: :parked,
        at: ~U[2026-09-24 09:30:00Z],
        calls: [
          %{
            id: "call_1",
            name: "github__issues",
            arguments: %{},
            prompt: "To connect github, open its authorization link.",
            authorization: true
          }
        ]
      }
    end

    test "is posted with Show link and Deny, and no link" do
      assert {:ok, _reply} = post(connecting_notice())
      assert_receive {:slack, "slack.com", "/api/chat.postMessage", message}

      assert %{"elements" => [show, deny]} =
               Enum.find(message["blocks"], &(&1["block_id"] == "wardrik:call_1"))

      assert show["action_id"] == "wardrik_link"
      assert deny["action_id"] == "wardrik_deny"
      refute JSON.encode!(message) =~ "https://"
      refute Enum.any?(message["blocks"], &(&1["type"] == "input"))
    end

    test "says to find the link with wardrik parked where there is no app token" do
      assert {:ok, _reply} =
               post(connecting_notice(), token: "xoxb-test", req_options: @req_options)

      assert_receive {:slack, _host, _path, message}
      assert JSON.encode!(message) =~ "Find the link with `wardrik parked`"
    end
  end
end
