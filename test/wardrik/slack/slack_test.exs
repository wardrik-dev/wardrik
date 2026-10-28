defmodule Wardrik.Slack.PackageTest do
  use ExUnit.Case, async: false
  use Mimic

  import Wardrik.Test.Slack

  setup :set_mimic_global
  setup :start_wardrik

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
      define(context.owner, "acme/triage", channels: ["slack"], description: "Triages.")

      event(context, %{type: "member_joined_channel", user: "UBOT", channel: "C1", inviter: "U1"})

      assert_receive {:slack, "chat.postMessage",
                      %{"channel" => "C1", "text" => ":wave: *triage* answers here now."} = posted},
                     1_000

      assert JSON.encode!(posted["blocks"]) =~ "Answer every message"
    end

    test "offers each agent to pick from, and says when there are none", context do
      joined_none = %{type: "member_joined_channel", user: "UBOT", channel: "C1"}
      event(context, joined_none)

      assert_receive {:slack, "chat.postMessage", %{"text" => "No agent answers here yet." <> _}},
                     1_000

      define(context.owner, "acme/one", channels: ["slack"])
      define(context.owner, "acme/two", channels: ["slack"])
      event(context, joined_none)
      assert_receive {:slack, "chat.postMessage", %{"text" => "Which agent" <> _}}, 1_000

      press(context, pressed("wardrik_room_agent", %{value: "acme/two"}, "U1", name: "maria"))

      assert_receive {:slack, {:respond, _path},
                      %{"replace_original" => true, "text" => ":wave: *two* answers here now."}},
                     1_000
    end

    test "has the agent answer every message, and stops it answering", context do
      define(context.owner, "acme/triage", channels: ["slack"])
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
      define(context.owner, "acme/triage", channels: ["slack"])
      joined(context)

      event(context, %{type: "channel_left", channel: "C1", actor_id: "U1"})
      event(context, message("<@UBOT> hi", "1.1"))

      refute_receive {:slack, "reactions.add", _params}, 200
    end
  end

  describe "threads" do
    setup context do
      define(context.owner, "acme/triage",
        channels: ["slack"],
        tools: ["tools"],
        policy: "careful"
      )

      joined(context)
      :ok
    end

    test "answers a mention in its thread, and marks the message", context do
      answers([answer("Two cases, both 2019.")])
      event(context, message("<@UBOT> how much Barolo is left?", "1.1"))

      assert_receive {:slack, "reactions.add", %{"name" => "eyes", "timestamp" => "1.1"}}, 1_000

      assert_receive {:slack, "chat.postMessage",
                      %{
                        "thread_ts" => "1.1",
                        "text" => "Two cases, both 2019.",
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

    test "asks an approver about a call, and says who decided", context do
      answers([calling("call_1", "echo", %{"text" => "hi"}), answer("Done.")])
      event(context, message("<@UBOT> echo hi", "1.1"))

      assert_receive {:slack, "chat.postMessage",
                      %{
                        "channel" => "U1",
                        "text" => "`triage` is waiting on you.",
                        "blocks" => blocks
                      }},
                     1_000

      assert JSON.encode!(blocks) =~ "Waiting on @maria to approve `echo`."

      assert JSON.encode!(blocks) =~
               "From `triage`, in <https://acme.slack.com/archives/C1/p1.1|a thread>"

      assert_receive {:slack, "chat.postMessage",
                      %{
                        "channel" => "C1",
                        "thread_ts" => "1.1",
                        "text" => "Waiting on @maria to approve `echo`."
                      } = said},
                     1_000

      refute Map.has_key?(said, "blocks")

      [%{"elements" => [approve | _deny]}] =
        for %{"type" => "actions"} = block <- blocks, do: block

      assert JSON.encode!(blocks) =~ ~s({\\"text\\":\\"hi\\"})

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

    test "tells someone who may not decide who may", context do
      answers([calling("call_1", "echo", %{"text" => "hi"}), answer("Done.")])
      event(context, message("<@UBOT> echo hi", "1.1"))

      assert_receive {:slack, "chat.postMessage",
                      %{
                        "channel" => "U1",
                        "blocks" => blocks,
                        "text" => "`triage` is waiting on you."
                      }},
                     1_000

      [%{"elements" => [_approve, deny]}] =
        for %{"type" => "actions"} = block <- blocks, do: block

      press(context, pressed("wardrik_deny", %{value: deny["value"]}, "U2", name: "jon"))

      assert_receive {:slack, {:respond, _path},
                      %{
                        "response_type" => "ephemeral",
                        "text" => "Only the channel's approvers" <> _
                      }},
                     1_000

      press(context, pressed("wardrik_deny", %{value: deny["value"]}, "U3", name: "ana"))
      assert_receive {:slack, "chat.postMessage", %{"text" => "Denied by ana: Rejected."}}, 1_000
      assert_receive {:slack, "reactions.add", %{"name" => "white_check_mark"}}, 1_000
    end

    @tag slack: [approvers: ["maria@example.com", "U2", "@ana", "@bot", "nobody@example.com"]]
    test "asks each approver Slack finds, by email, ID or handle", context do
      answers([calling("call_1", "echo", %{"text" => "hi"})])
      event(context, message("<@UBOT> echo hi", "1.1"))

      for member <- ["U1", "U2", "U3"],
          do:
            assert_receive(
              {:slack, "chat.postMessage", %{"channel" => ^member, "blocks" => _blocks}},
              1_000
            )

      assert_receive {:slack, "chat.postMessage", %{"channel" => "U4"}}, 1_000

      assert_receive {:slack, "chat.postMessage",
                      %{
                        "channel" => "C1",
                        "text" =>
                          "Waiting on maria@example.com, <@U2>, @ana, @bot or nobody@example.com to approve `echo`."
                      }},
                     1_000
    end

    @tag slack: [approvers: ["@ghost", "@bot"]]
    test "asks in the thread where it reaches no approver", context do
      answers([calling("call_1", "echo", %{"text" => "hi"})])
      event(context, message("<@UBOT> echo hi", "1.1"))

      assert_receive {:slack, "chat.postMessage",
                      %{
                        "channel" => "C1",
                        "thread_ts" => "1.1",
                        "text" => "Waiting on @ghost or @bot" <> _,
                        "blocks" => blocks
                      }},
                     1_000

      assert JSON.encode!(blocks) =~ "wardrik_approve"
    end

    test "says a run stopped, and why one failed", context do
      answers([calling("call_1", "echo", %{"text" => "hi"})])
      event(context, message("<@UBOT> echo hi", "1.1"))
      assert_receive {:slack, "chat.postMessage", %{"text" => "Waiting" <> _}}, 1_000

      Wardrik.Agent.cancel(context.owner, "acme/triage/slack.T1.C1.1.1")

      assert_receive {:slack, "reactions.remove", %{"name" => "eyes", "timestamp" => "1.1"}},
                     1_000

      assert_receive {:slack, "assistant.threads.setStatus", %{"status" => ""}}, 1_000

      Mimic.stub(ReqLLM, :stream_text, fn _model, _messages, _opts ->
        {:error, %RuntimeError{message: "The model is down."}}
      end)

      event(context, message("<@UBOT> again", "2.1"))

      assert_receive {:slack, "chat.postMessage",
                      %{"text" => ":warning: It stopped with an error: " <> _reason}},
                     5_000
    end

    test "says why it couldn't ask the agent", context do
      Wardrik.Agent.forget(context.owner, "acme/triage")
      event(context, message("<@UBOT> hi", "1.1"))

      assert_receive {:slack, "chat.postMessage",
                      %{"thread_ts" => "1.1", "text" => ":warning:" <> _}},
                     1_000
    end

    test "tells whoever presses Show link where to sign in, or why not", context do
      value = JSON.encode!(%{c: "acme/triage/slack.T1.C1.1.1", i: "call_1", n: "inbox"})
      press(context, pressed("wardrik_link", %{value: value}, "U3"))

      assert_receive {:slack, {:respond, _path}, %{"response_type" => "ephemeral"}}, 1_000

      press(context, pressed("wardrik_approve", %{value: "not json"}, "U3"))
      refute_receive {:slack, {:respond, _path}, _reply}, 200
    end
  end

  describe "notices" do
    test "posts what a turn answered in the room the route names", context do
      define(context.owner, "acme/digest", notify: %{to: ["slack:#news"], on: ["finished"]})
      answers([answer("Three things happened.")])
      {:ok, _message} = Wardrik.Agent.ask(context.owner, "acme/digest", content: "Go")

      assert_receive {:slack, "chat.postMessage",
                      %{"channel" => "#news", "text" => "digest: Three things happened."} =
                        posted},
                     1_000

      refute Map.has_key?(posted, "thread_ts")
    end

    @tag notify: [
           targets: [
             ops: {Wardrik.Notify.Room, channel: "slack", room: "#ops", approvers: ["@maria"]}
           ]
         ]
    test "asks a target's approvers about a parked turn, in the room and directly", context do
      define(context.owner, "acme/triage", tools: ["tools"], policy: "careful", notify: "ops")
      answers([calling("call_1", "echo", %{"text" => "hi"}), answer("Done.")])
      {:ok, _message} = Wardrik.Agent.ask(context.owner, "acme/triage", content: "Echo hi")

      assert_receive {:slack, "chat.postMessage",
                      %{
                        "channel" => "#ops",
                        "text" => "`triage` waits on @maria to approve `echo`."
                      }},
                     1_000

      assert_receive {:slack, "chat.postMessage", %{"channel" => "U1", "blocks" => blocks}}, 1_000
      assert JSON.encode!(blocks) =~ "a notice"

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
