defmodule WardrikSlackTest do
  use ExUnit.Case, async: false

  import WardrikSlack.Test

  setup :start_slack

  defp joined(context) do
    event(context, %{type: "member_joined_channel", user: "UBOT", channel: "C1", inviter: "U1"})
    assert_receive {:slack, "chat.postMessage", %{"text" => ":wave:" <> _rest}}, 1_000
  end

  defp pressed(action, value, user, opts \\ []) do
    %{
      type: "block_actions",
      user: %{id: user, username: Keyword.get(opts, :name)},
      channel: %{id: "C1"},
      response_url: "https://hooks.slack.com/actions/1",
      actions: [Map.merge(%{action_id: action}, value)],
      state: Keyword.get(opts, :state, %{values: %{}}),
      message: %{blocks: Keyword.get(opts, :blocks, [])}
    }
  end

  test "refuses an option it doesn't take, so a typo doesn't go unnoticed", %{channel: channel} do
    assert_raise NimbleOptions.ValidationError, ~r/unknown options \[:signin_secret\]/, fn ->
      WardrikSlack.children(%{channel | options: [signin_secret: "s3cret"]})
    end
  end

  test "gives the options it takes beyond Wardrik.Chat's" do
    assert {:ok, [req_options: [], app_token: "xapp-1"]} =
             NimbleOptions.validate([app_token: "xapp-1"], WardrikSlack.schema())
  end

  test "checks the tokens it's given", context do
    req_options = [req_options: context.channel.options[:req_options]]

    assert WardrikSlack.check([token: "xoxb-test"] ++ req_options) ==
             {:ok, "posts as @wardrik in Acme"}

    assert WardrikSlack.check([token: "xoxb-test", app_token: "xapp-test"] ++ req_options) ==
             {:error, ~s(Slack refused its app_token: "invalid_auth")}

    assert {:ok, "keeps a token for each workspace" <> _} = WardrikSlack.check(req_options)
  end

  describe "requests" do
    test "answers Slack's check of the Request URL", context do
      body = JSON.encode!(%{type: "url_verification", challenge: "c4ll3nge"})
      assert %{status: 200, body: "c4ll3nge"} = deliver(context, "events", body)
    end

    test "refuses what Slack didn't sign, or signed too long ago", context do
      body = JSON.encode!(%{type: "url_verification", challenge: "c"})

      assert %{status: 401} = deliver(context, "events", body, secret: "wrong")
      assert %{status: 401} = deliver(context, "events", body, at: System.os_time(:second) - 600)
      assert %{status: 404} = deliver(context, "nowhere", body)
      assert %{status: 400} = deliver(context, "actions", "payload=nope")
      assert %{status: 200, body: ""} = deliver(context, "events", ~s({"type":"other"}))
    end

    @tag slack: [signing_secret: nil]
    test "takes nothing over HTTP without a signing secret", context do
      assert %{status: 404} = deliver(context, "events", "{}")
    end
  end

  describe "rooms" do
    test "says which agent answers once the bot is invited", context do
      define(context.owner, "agt_triage", channels: ["slack"], description: "Triages.")

      event(context, %{type: "member_joined_channel", user: "UBOT", channel: "C1", inviter: "U1"})

      assert_receive {:slack, "chat.postMessage",
                      %{"channel" => "C1", "text" => ":wave: *agt_triage* answers here now."} =
                        posted},
                     1_000

      assert JSON.encode!(posted["blocks"]) =~ "Answer every message"
    end

    test "offers each agent to pick from, and says when there are none", context do
      joined_none = %{type: "member_joined_channel", user: "UBOT", channel: "C1"}
      event(context, joined_none)

      assert_receive {:slack, "chat.postMessage", %{"text" => "No agent answers here yet." <> _}},
                     1_000

      define(context.owner, "agt_one", channels: ["slack"])
      define(context.owner, "agt_two", channels: ["slack"])
      event(context, joined_none)
      assert_receive {:slack, "chat.postMessage", %{"text" => "Which agent" <> _}}, 1_000

      press(context, pressed("wardrik_room_agent", %{value: "agt_two"}, "U1", name: "maria"))

      assert_receive {:slack, {:respond, _path},
                      %{
                        "replace_original" => true,
                        "text" => ":wave: *agt_two* answers here now."
                      }},
                     1_000
    end

    test "has the agent answer every message, and stops it answering", context do
      define(context.owner, "agt_triage", channels: ["slack"])
      joined(context)

      press(context, pressed("wardrik_room_answers", %{value: "everything"}, "U1"))
      assert_receive {:slack, {:respond, _path}, %{"blocks" => blocks}}, 1_000
      assert JSON.encode!(blocks) =~ "every message here"

      press(context, pressed("wardrik_room_more", %{selected_option: %{value: "stop"}}, "U1"))
      assert_receive {:slack, {:respond, _path}, %{"text" => "No agent answers here now."}}, 1_000

      press(context, pressed("wardrik_room_more", %{selected_option: %{value: "choose"}}, "U1"))
      assert_receive {:slack, {:respond, _path}, %{"text" => "Which agent" <> _}}, 1_000
    end

    test "unbinds a Slack channel the bot leaves", context do
      define(context.owner, "agt_triage", channels: ["slack"])
      joined(context)

      event(context, %{type: "channel_left", channel: "C1", actor_id: "U1"})
      event(context, message("<@UBOT> hi", "1.1"))

      refute_receive {:slack, "reactions.add", _params}, 200
    end
  end

  describe "threads" do
    setup context do
      define(context.owner, "agt_triage",
        channels: ["slack"],
        tools: ["tools"],
        policy: "careful"
      )

      joined(context)
      :ok
    end

    test "answers a mention in its thread, and marks the message", context do
      event(context, message("<@UBOT> how much Barolo is left?", "1.1"))

      assert_receive {:slack, "reactions.add", %{"name" => "eyes", "timestamp" => "1.1"}}, 1_000

      assert_receive {:slack, "chat.postMessage",
                      %{
                        "thread_ts" => "1.1",
                        "text" => "Answered: how much Barolo is left?",
                        "blocks" => [%{"type" => "markdown"}]
                      }},
                     1_000

      assert_receive {:slack, "reactions.add", %{"name" => "white_check_mark"}}, 1_000
    end

    test "leaves alone edits, bots, direct messages and what isn't for it", context do
      event(context, message("hi", "1.1"))
      event(context, message("<@UBOT> hi", "1.2", subtype: "message_changed"))
      event(context, message("<@UBOT> hi", "1.3", bot_id: "B1"))
      event(context, message("<@UBOT> hi", "1.4", channel_type: "im"))
      event(context, message("<@UBOT> hi", "1.5", user: "UBOT"))

      refute_receive {:slack, "reactions.add", _params}, 200
    end

    test "asks in the thread about a call, and says who decided", context do
      event(context, message("<@UBOT> echo hi", "1.1"))

      assert_receive {:slack, "chat.postMessage",
                      %{
                        "channel" => "C1",
                        "thread_ts" => "1.1",
                        "text" => "Waiting for someone to approve `echo`.",
                        "blocks" => blocks
                      }},
                     1_000

      [%{"elements" => [approve | _deny]}] =
        for %{"type" => "actions"} = block <- blocks, do: block

      assert JSON.encode!(blocks) =~ ~s({\\"text\\":\\"hi\\"})

      assert %{"g" => "agt_triage", "c" => "slack.T1.C1.1.1", "i" => "call_1"} =
               JSON.decode!(approve["value"])

      state = %{values: %{"wardrik-note:call_1" => %{note: %{value: " Go ahead. "}}}}

      press(
        context,
        pressed("wardrik_approve", %{value: approve["value"]}, "U1",
          name: "maria",
          state: state,
          blocks: blocks
        )
      )

      assert_receive {:slack, {:respond, _path},
                      %{"replace_original" => true, "text" => "Approved echo"}},
                     1_000

      assert_receive {:slack, "chat.postMessage", %{"text" => "Approved by maria: Go ahead."}},
                     1_000

      assert_receive {:slack, "chat.postMessage", %{"text" => "Done."}}, 1_000
      assert_receive {:slack, "reactions.add", %{"name" => "white_check_mark"}}, 1_000
    end

    test "refuses a member your app doesn't let decide, unless they asked", context do
      event(context, message("<@UBOT> echo hi", "1.1"))

      assert_receive {:slack, "chat.postMessage",
                      %{"text" => "Waiting for someone" <> _, "blocks" => blocks}},
                     1_000

      [%{"elements" => [_approve, deny]}] =
        for %{"type" => "actions"} = block <- blocks, do: block

      press(context, pressed("wardrik_deny", %{value: deny["value"]}, "U2", name: "jon"))

      assert_receive {:slack, {:respond, _path},
                      %{
                        "response_type" => "ephemeral",
                        "text" => "You may not decide what this agent waits on."
                      }},
                     1_000

      press(context, pressed("wardrik_deny", %{value: deny["value"]}, "U3", name: "ana"))
      assert_receive {:slack, "chat.postMessage", %{"text" => "Denied by ana: Rejected."}}, 1_000
      assert_receive {:slack, "reactions.add", %{"name" => "white_check_mark"}}, 1_000
    end

    test "tells a member your app doesn't know why they can't ask", context do
      event(context, message("<@UBOT> echo hi", "1.1", user: "U9"))

      assert_receive {:slack, "chat.postMessage",
                      %{"thread_ts" => "1.1", "text" => ":warning: Nobody here knows you yet."}},
                     1_000

      refute_receive {:slack, "reactions.add", _params}, 200
    end

    test "tells a member your app doesn't know why they can't decide", context do
      event(context, message("<@UBOT> echo hi", "1.1"))

      assert_receive {:slack, "chat.postMessage",
                      %{"text" => "Waiting for someone" <> _, "blocks" => blocks}},
                     1_000

      [%{"elements" => [approve | _deny]}] =
        for %{"type" => "actions"} = block <- blocks, do: block

      press(context, pressed("wardrik_approve", %{value: approve["value"]}, "U9", name: "eve"))

      assert_receive {:slack, {:respond, _path},
                      %{"response_type" => "ephemeral", "text" => "Nobody here knows you yet."}},
                     1_000

      refute_receive {:slack, "chat.postMessage", %{"text" => "Approved" <> _}}, 200
    end

    test "says a run stopped, and why one failed", context do
      event(context, message("<@UBOT> echo hi", "1.1"))
      assert_receive {:slack, "chat.postMessage", %{"text" => "Waiting" <> _}}, 1_000

      :ok = Wardrik.Agent.cancel(context.owner, "agt_triage", conversation: "slack.T1.C1.1.1")

      assert_receive {:slack, "reactions.remove", %{"name" => "eyes", "timestamp" => "1.1"}},
                     1_000

      assert_receive {:slack, "assistant.threads.setStatus", %{"status" => ""}}, 1_000

      event(context, message("<@UBOT> fail again", "2.1"))

      assert_receive {:slack, "chat.postMessage",
                      %{"text" => ":warning: It stopped with an error: " <> _reason}},
                     5_000
    end

    test "tells whoever presses Show link where to sign in, or why not", context do
      value = JSON.encode!(%{g: "agt_triage", c: "slack.T1.C1.1.1", i: "call_1", n: "inbox"})
      press(context, pressed("wardrik_link", %{value: value}, "U3"))

      assert_receive {:slack, {:respond, _path}, %{"response_type" => "ephemeral"}}, 1_000

      press(context, pressed("wardrik_approve", %{value: "not json"}, "U3"))
      refute_receive {:slack, {:respond, _path}, _reply}, 200
    end
  end

  describe "notices" do
    test "posts what a turn answered in the room the route names", context do
      notice = %Wardrik.Notice{
        agent: "agt_digest",
        kind: :finished,
        at: DateTime.utc_now(),
        text: "Three things happened."
      }

      notification = %Wardrik.Channel.Notification{workspace: "T1", room: "#news", notice: notice}
      assert WardrikSlack.notify(notification, context.options) == :ok

      assert_receive {:slack, "chat.postMessage",
                      %{"channel" => "#news", "text" => "agt_digest: Three things happened."} =
                        posted},
                     1_000

      refute Map.has_key?(posted, "thread_ts")
    end

    test "posts no notice of a turn in one of its threads, which shows it", context do
      {:ok, workspace} =
        Wardrik.Chat.workspace(Wardrik.Chat.channel(WardrikSlack, context.options), "T1")

      notice = %Wardrik.Notice{
        agent: "agt_digest",
        conversation: Wardrik.Chat.Workspace.conversation(workspace, room: "C1", thread: "1.1"),
        kind: :finished,
        at: DateTime.utc_now(),
        text: "Three things happened."
      }

      notification = %Wardrik.Channel.Notification{workspace: "T1", room: "#news", notice: notice}

      assert {:skip, "but its turn was in a Slack thread" <> _rest} =
               WardrikSlack.notify(notification, context.options)

      refute_receive {:slack, "chat.postMessage", _posted}, 200
    end

    test "asks about a parked turn in the room", context do
      interrupt = %Wardrik.Interrupt{
        id: "call_1",
        tool_call_id: "call_1",
        reason: :tool_approval,
        name: "echo",
        message: "Run echo?"
      }

      notice = %Wardrik.Notice{
        agent: "agt_triage",
        kind: :parked,
        at: DateTime.utc_now(),
        calls: [%{interrupt: interrupt, arguments: %{"text" => "hi"}}]
      }

      notification = %Wardrik.Channel.Notification{workspace: "T1", room: "#ops", notice: notice}

      assert WardrikSlack.notify(notification, context.options) == :ok

      assert_receive {:slack, "chat.postMessage",
                      %{
                        "channel" => "#ops",
                        "text" => "`agt_triage` waits for someone to approve `echo`.",
                        "blocks" => blocks
                      }},
                     1_000

      [%{"elements" => [approve | _deny]}] =
        for %{"type" => "actions"} = block <- blocks, do: block

      press(
        context,
        pressed("wardrik_approve", %{value: approve["value"]}, "U1",
          name: "maria",
          blocks: blocks
        )
      )

      assert_receive {:slack, {:respond, _path}, %{"text" => "Approved echo"}}, 1_000
    end
  end

  describe "the app taken out" do
    test "forgets its installation", context do
      callback = %{type: "event_callback", team_id: "T1", event: %{type: "app_uninstalled"}}
      assert %{status: 200} = deliver(context, "events", JSON.encode!(callback))
    end
  end
end
