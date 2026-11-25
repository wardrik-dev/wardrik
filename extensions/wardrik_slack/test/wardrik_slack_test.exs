defmodule WardrikSlackTest do
  use ExUnit.Case, async: false

  import WardrikSlack.Test

  setup :start_slack

  defp join(context) do
    event(context, %{type: "member_joined_channel", user: "UBOT", channel: "C1", inviter: "U1"})
    assert_receive {:slack, "chat.postMessage", %{"text" => ":wave:" <> _rest}}, 1_000
  end

  defp build_press(action, value, user, opts \\ []) do
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

      press(context, build_press("wardrik_room_agent", %{value: "agt_two"}, "U1", name: "maria"))

      assert_receive {:slack, {:respond, _path},
                      %{
                        "replace_original" => true,
                        "text" => ":wave: *agt_two* answers here now."
                      }},
                     1_000
    end

    test "has the agent answer every message, and stops it answering", context do
      define(context.owner, "agt_triage", channels: ["slack"])
      join(context)

      press(context, build_press("wardrik_room_answers", %{value: "everything"}, "U1"))
      assert_receive {:slack, {:respond, _path}, %{"blocks" => blocks}}, 1_000
      assert JSON.encode!(blocks) =~ "every message here"

      press(context, build_press("wardrik_room_more", %{selected_option: %{value: "stop"}}, "U1"))
      assert_receive {:slack, {:respond, _path}, %{"text" => "No agent answers here now."}}, 1_000

      press(
        context,
        build_press("wardrik_room_more", %{selected_option: %{value: "choose"}}, "U1")
      )

      assert_receive {:slack, {:respond, _path}, %{"text" => "Which agent" <> _}}, 1_000
    end

    test "unbinds a Slack channel the bot leaves", context do
      define(context.owner, "agt_triage", channels: ["slack"])
      join(context)

      event(context, %{type: "channel_left", channel: "C1", actor_id: "U1"})
      event(context, message("<@UBOT> hi", "1.1"))

      refute_receive {:slack, "reactions.add", _params}, 200
    end
  end

  describe "direct messages" do
    @describetag slack: [direct: {WardrikSlack.Test.Assistant, agent: "agt_triage"}]

    setup context do
      define(context.owner, "agt_triage", channels: ["slack"])
      :ok
    end

    test "offers the next steps as the Messages tab's prompts in a direct message", context do
      event(context, message("echo hi", "2.1", channel: "D1", channel_type: "im"))

      log = {"agt_triage", "slack.T1.D1.2.1"}
      suggested = {"prompts.suggested", "agents/agt_triage", %{"prompts" => ["Send it"]}}

      assert_receive {:slack, "chat.postMessage",
                      %{"text" => "Waiting" <> _, "blocks" => blocks}},
                     1_000

      :ok = Wardrik.EventLog.append(context.events, log, suggested)

      [%{"elements" => [approve | _deny]}] =
        for %{"type" => "actions"} = block <- blocks, do: block

      press(
        context,
        build_press("wardrik_approve", %{value: approve["value"]}, "U3", name: "ana")
      )

      assert_receive {:slack, "chat.postMessage", %{"text" => "Done.", "blocks" => blocks}}, 1_000
      refute Enum.any?(blocks, &(&1["block_id"] == "wardrik_prompts"))

      assert_receive {:slack, "assistant.threads.setSuggestedPrompts",
                      %{"channel_id" => "D1", "prompts" => [%{"message" => "Send it"}]} = params},
                     1_000

      refute Map.has_key?(params, "thread_ts")
    end

    test "answers each in its thread, unmentioned, and marks the message", context do
      event(
        context,
        message("how much Barolo is left?", "2.1", channel: "D1", channel_type: "im")
      )

      assert_receive {:slack, "reactions.add", %{"name" => "eyes", "timestamp" => "2.1"}}, 1_000

      assert_receive {:slack, "chat.startStream",
                      %{"channel" => "D1", "thread_ts" => "2.1", "recipient_user_id" => "U3"}},
                     1_000

      assert_receive {:slack, "chat.stopStream", %{"channel" => "D1", "ts" => "9.8"}}, 1_000

      assert_receive {:slack, "chat.postMessage",
                      %{"text" => "Answered: how much Barolo is left?"}},
                     1_000

      assert_receive {:slack, "reactions.add",
                      %{"name" => "white_check_mark", "timestamp" => "2.1"}},
                     1_000
    end

    test "quote the message a reply answers, once, in a thread no agent answers in", context do
      event(context, message("why?", "3.2", channel: "D1", channel_type: "im", thread_ts: "3.1"))

      assert_receive {:slack, "conversations.replies",
                      %{"channel" => "D1", "ts" => "3.1", "include_all_metadata" => "true"}},
                     1_000

      assert_receive {:slack, "chat.postMessage",
                      %{"thread_ts" => "3.1", "text" => "Answered: " <> answered}},
                     1_000

      assert answered ==
               "This replies in the thread of this message:\n" <>
                 "> *triage* stopped with an error: :crash\n" <>
                 "It's a notice about triage (agt_triage), from its main conversation.\n\nwhy?"

      event(context, message("and?", "3.3", channel: "D1", channel_type: "im", thread_ts: "3.1"))

      assert_receive {:slack, "chat.postMessage",
                      %{"thread_ts" => "3.1", "text" => "Answered: and?"}},
                     1_000

      assert_receive {:slack, "reactions.add",
                      %{"name" => "white_check_mark", "timestamp" => "3.3"}},
                     1_000

      refute_received {:slack, "conversations.replies", _params}
    end

    @tag slack: [direct: nil]
    test "says so where no agent answers them", context do
      event(context, message("hi", "2.2", channel: "D1", channel_type: "im"))

      assert_receive {:slack, "chat.postMessage",
                      %{
                        "channel" => "D1",
                        "thread_ts" => "2.2",
                        "text" => ":warning: No agent answers direct messages here."
                      }},
                     1_000
    end
  end

  describe "threads" do
    setup context do
      define(context.owner, "agt_triage",
        channels: ["slack"],
        tools: ["tools"],
        policy: "careful"
      )

      join(context)
      :ok
    end

    test "answers a mention in its thread, and marks the message", context do
      event(context, message("<@UBOT> how much Barolo is left?", "1.1"))

      assert_receive {:slack, "reactions.add", %{"name" => "eyes", "timestamp" => "1.1"}}, 1_000

      assert_receive {:slack, "chat.startStream",
                      %{
                        "channel" => "C1",
                        "thread_ts" => "1.1",
                        "recipient_user_id" => "U3",
                        "recipient_team_id" => "T1",
                        "chunks" => [
                          %{
                            "type" => "task_update",
                            "title" => "Thinking",
                            "status" => "in_progress"
                          }
                        ]
                      }},
                     1_000

      assert_receive {:slack, "chat.appendStream",
                      %{"ts" => "9.8", "chunks" => [%{"status" => "complete"}]}},
                     1_000

      assert_receive {:slack, "chat.stopStream", %{"ts" => "9.8"}}, 1_000

      assert_receive {:slack, "chat.postMessage",
                      %{"text" => "Answered: how much Barolo is left?"}},
                     1_000

      assert_receive {:slack, "reactions.add", %{"name" => "white_check_mark"}}, 1_000
      refute_received {:slack, "chat.postMessage", %{"thread_ts" => "1.1"}}
    end

    test "puts feedback buttons under a reply, and keeps each press in the log", context do
      event(context, message("<@UBOT> hi", "1.1"))

      assert_receive {:slack, "chat.postMessage",
                      %{
                        "text" => "Answered: hi",
                        "blocks" => [
                          %{"type" => "markdown"},
                          %{
                            "type" => "context_actions",
                            "elements" => [
                              %{
                                "type" => "feedback_buttons",
                                "action_id" => "wardrik_feedback",
                                "negative_button" => %{"value" => negative}
                              }
                            ]
                          }
                        ]
                      }},
                     1_000

      assert %{"g" => "agt_triage", "c" => "slack.T1.C1.1.1", "r" => "r1", "v" => "negative"} =
               JSON.decode!(negative)

      press(context, build_press("wardrik_feedback", %{value: negative}, "U9", name: "stranger"))

      assert_receive {:slack, {:respond, _path},
                      %{"response_type" => "ephemeral", "text" => "Nobody here knows you yet."}},
                     1_000

      press(context, build_press("wardrik_feedback", %{value: negative}, "U3", name: "ana"))

      assert_receive {:slack, {:respond, _path},
                      %{"response_type" => "ephemeral", "text" => "Thanks, noted."}},
                     1_000

      {:ok, %{events: events}} =
        Wardrik.EventLog.page(context.events, [{"agt_triage", "slack.T1.C1.1.1"}])

      assert [%{"data" => %{"rating" => "negative", "rated_by" => %{"id" => "ana"}}}] =
               for(%{"type" => "wardrik.run.rated"} = event <- events, do: event)
    end

    test "shows its steps in a message it edits, where Slack won't stream", context do
      event(context, message("<@UBOT> hi", "3.1"))

      assert_receive {:slack, "chat.postMessage",
                      %{
                        "thread_ts" => "3.1",
                        "text" => "Working…",
                        "blocks" => [
                          %{"type" => "markdown", "text" => ":hourglass_flowing_sand: Thinking"}
                        ]
                      }},
                     1_000

      assert_receive {:slack, "chat.update",
                      %{
                        "ts" => "9.9",
                        "blocks" => [%{"text" => ":white_check_mark: Thinking"}]
                      }},
                     1_000

      assert_receive {:slack, "chat.postMessage",
                      %{"thread_ts" => "3.1", "text" => "Answered: hi"}},
                     1_000
    end

    test "leaves alone edits, bots, group direct messages and what isn't for it", context do
      event(context, message("hi", "1.1"))
      event(context, message("<@UBOT> hi", "1.2", subtype: "message_changed"))
      event(context, message("<@UBOT> hi", "1.3", bot_id: "B1"))
      event(context, message("<@UBOT> hi", "1.4", channel_type: "mpim"))
      event(context, message("<@UBOT> hi", "1.5", user: "UBOT"))

      refute_receive {:slack, "reactions.add", _params}, 200
    end

    defp approve_with_next_steps(context, thread, prompts) do
      log = {"agt_triage", "slack.T1.C1.#{thread}"}
      suggested = {"prompts.suggested", "agents/agt_triage", %{"prompts" => prompts}}
      :ok = Wardrik.EventLog.append(context.events, log, suggested)

      assert_receive {:slack, "chat.postMessage",
                      %{"text" => "Waiting" <> _, "blocks" => blocks}},
                     1_000

      [%{"elements" => [approve | _deny]}] =
        for %{"type" => "actions"} = block <- blocks, do: block

      press(
        context,
        build_press("wardrik_approve", %{value: approve["value"]}, "U1", name: "maria")
      )
    end

    test "offers the next steps a run suggested as buttons under its reply", context do
      event(context, message("<@UBOT> echo hi", "1.1"))
      approve_with_next_steps(context, "1.1", ["Send it", "Not yet"])

      assert_receive {:slack, "chat.postMessage",
                      %{
                        "text" => "Done.",
                        "blocks" => [
                          %{"type" => "markdown"},
                          %{
                            "type" => "actions",
                            "block_id" => "wardrik_prompts",
                            "elements" => [
                              %{"action_id" => "wardrik_prompt:0", "value" => "Send it"},
                              %{"action_id" => "wardrik_prompt:1", "value" => "Not yet"}
                            ]
                          },
                          %{"type" => "context_actions"}
                        ]
                      } = reply},
                     1_000

      press(context, %{
        type: "block_actions",
        user: %{id: "U3", username: "ana"},
        channel: %{id: "C1"},
        response_url: "https://hooks.slack.com/actions/1",
        actions: [%{action_id: "wardrik_prompt:0", value: "Send it"}],
        message: %{thread_ts: "1.1", text: "Done.", blocks: reply["blocks"]}
      })

      assert_receive {:slack, "chat.postMessage",
                      %{"thread_ts" => "1.1", "text" => "<@U3> asked: Send it"}},
                     1_000

      assert_receive {:slack, {:respond, _path},
                      %{
                        "replace_original" => true,
                        "blocks" => [_markdown, %{"type" => "context_actions"}]
                      }},
                     1_000

      assert_receive {:slack, "chat.postMessage", %{"text" => "Answered: Send it"}}, 1_000
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
        build_press("wardrik_approve", %{value: approve["value"]}, "U1",
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

      assert_receive {:slack, "chat.stopStream", %{}}, 1_000

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

      press(context, build_press("wardrik_deny", %{value: deny["value"]}, "U2", name: "jon"))

      assert_receive {:slack, {:respond, _path},
                      %{
                        "response_type" => "ephemeral",
                        "text" => "You may not decide what this agent waits on."
                      }},
                     1_000

      press(context, build_press("wardrik_deny", %{value: deny["value"]}, "U3", name: "ana"))
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

      press(
        context,
        build_press("wardrik_approve", %{value: approve["value"]}, "U9", name: "eve")
      )

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

      event(context, message("<@UBOT> fail again", "2.1"))

      assert_receive {:slack, "chat.postMessage",
                      %{"text" => ":warning: It stopped with an error: " <> _reason}},
                     5_000
    end

    test "tells whoever presses Show link where to sign in, or why not", context do
      value = JSON.encode!(%{g: "agt_triage", c: "slack.T1.C1.1.1", i: "call_1", n: "inbox"})
      press(context, build_press("wardrik_link", %{value: value}, "U3"))

      assert_receive {:slack, {:respond, _path}, %{"response_type" => "ephemeral"}}, 1_000

      press(context, build_press("wardrik_approve", %{value: "not json"}, "U3"))
      refute_receive {:slack, {:respond, _path}, _reply}, 200
    end
  end

  describe "the agent experience" do
    setup context do
      define(context.owner, "agt_triage", channels: ["slack"])
      event(context, %{type: "member_joined_channel", user: "UBOT", channel: "C1", inviter: "U1"})
      assert_receive {:slack, "chat.postMessage", %{"text" => ":wave:" <> _rest}}, 1_000
      :ok
    end

    defp open_tab(tab), do: %{type: "app_home_opened", user: "U3", channel: "D1", tab: tab}

    @tag slack: [
           prompts:
             {Wardrik.Chat.Prompts.Fixed, prompts: ["Plan my week", "Summarize this channel"]}
         ]
    test "suggests the channel's prompts when the Messages tab opens", context do
      event(context, open_tab("messages"))

      assert_receive {:slack, "assistant.threads.setSuggestedPrompts", params}, 1_000

      assert params == %{
               "channel_id" => "D1",
               "prompts" => [
                 %{"title" => "Plan my week", "message" => "Plan my week"},
                 %{"title" => "Summarize this channel", "message" => "Summarize this channel"}
               ]
             }

      event(context, open_tab("home"))
      refute_receive {:slack, "assistant.threads.setSuggestedPrompts", _params}, 200
    end

    test "suggests Wardrik's own prompts where the channel names none", context do
      event(context, open_tab("messages"))

      assert_receive {:slack, "assistant.threads.setSuggestedPrompts", %{"prompts" => prompts}},
                     1_000

      assert Enum.map(prompts, & &1["message"]) == Wardrik.Chat.Prompts.defaults()
    end

    @tag slack: [prompts: {Wardrik.Chat.Prompts.Fixed, prompts: []}]
    test "suggests nothing where the channel's prompts are none", context do
      event(context, open_tab("messages"))
      refute_receive {:slack, "assistant.threads.setSuggestedPrompts", _params}, 200
    end

    test "suggests prompts in each thread for an app on the older assistant experience",
         context do
      started = %{
        type: "assistant_thread_started",
        assistant_thread: %{user_id: "U3", channel_id: "D1", thread_ts: "5.1"}
      }

      event(context, started)

      assert_receive {:slack, "assistant.threads.setSuggestedPrompts",
                      %{"channel_id" => "D1", "thread_ts" => "5.1"}},
                     1_000
    end

    test "stops the run when Stop is pressed", context do
      event(context, message("<@UBOT> echo hi", "1.1"))
      assert_receive {:slack, "chat.postMessage", %{"text" => "Waiting" <> _}}, 1_000

      event(context, %{type: "agent_session_stopped", channel: "C1", thread_ts: "1.1", user: "U3"})

      assert_receive {:slack, "reactions.remove", %{"name" => "eyes", "timestamp" => "1.1"}},
                     1_000
    end

    test "sets a session with nothing running back to active", context do
      event(context, %{type: "agent_session_stopped", channel: "C1", thread_ts: "9.1", user: "U3"})

      assert_receive {:slack, "agents.sessions.setStatus",
                      %{"channel_id" => "C1", "thread_ts" => "9.1", "status" => "active"}},
                     1_000
    end
  end

  describe "the Home tab" do
    setup context do
      define(context.owner, "agt_triage", channels: ["slack"], description: "Sorts the inbox.")
      event(context, %{type: "member_joined_channel", user: "UBOT", channel: "C1", inviter: "U1"})
      assert_receive {:slack, "chat.postMessage", %{"text" => ":wave:" <> _rest}}, 1_000
      :ok
    end

    defp open_home(user \\ "U3"), do: %{type: "app_home_opened", user: user, tab: "home"}

    defp texts(blocks), do: Enum.map(blocks, &(get_in(&1, ["text", "text"]) || ""))

    test "shows the member's agents and the calls they wait on, linked to their threads",
         context do
      event(context, open_home())
      assert_receive {:slack, "views.publish", %{"user_id" => "U3", "view" => view}}, 1_000
      assert %{"type" => "home", "blocks" => blocks} = view

      assert texts(blocks) == [
               "Agents",
               "*agt_triage* · Idle\nSorts the inbox.",
               "Waiting for a decision",
               "Nothing is waiting for a decision."
             ]

      event(context, message("<@UBOT> echo hi", "1.1"))
      assert_receive {:slack, "chat.postMessage", %{"text" => "Waiting" <> _}}, 1_000

      event(context, open_home())
      assert_receive {:slack, "views.publish", %{"view" => %{"blocks" => blocks}}}, 1_000

      assert [_agents, agent, _waiting, call] = texts(blocks)
      assert agent == "*agt_triage* · Waiting on 1 conversation\nSorts the inbox."
      assert call =~ "`echo`"
      assert call =~ "<https://acme.slack.com/archives/C1/p1.1|Open the thread to decide>"
    end

    test "tells a member nobody knows why there's nothing to show", context do
      event(context, open_home("U9"))
      assert_receive {:slack, "views.publish", %{"view" => %{"blocks" => blocks}}}, 1_000
      assert texts(blocks) == ["Nobody here knows you yet."]
    end

    @tag slack: [home: {WardrikSlackTest.Home, greeting: "Hello"}]
    test "shows the page the channel's :home names", context do
      event(context, open_home())
      assert_receive {:slack, "views.publish", %{"view" => %{"blocks" => blocks}}}, 1_000
      assert ["Hello, U3", "Agents" | _rest] = texts(blocks)
    end

    @tag slack: [home: false]
    test "leaves the tab alone when :home is false", context do
      event(context, open_home())
      refute_receive {:slack, "views.publish", _params}, 200
    end
  end

  describe "progress" do
    setup context do
      {:ok, workspace} = Wardrik.Chat.workspace(context.channel, "T1")
      %{workspace: workspace}
    end

    defp progress(workspace, progress, steps) do
      outbound = %Wardrik.Chat.Outbound{
        installation: workspace.installation,
        room: "C1",
        thread: "1.1",
        body: {:progress, steps},
        progress: progress,
        asker: "U3"
      }

      WardrikSlack.deliver(outbound, workspace.channel)
    end

    test "shows how long a quiet step has run, its details, and a failed one", context do
      since = DateTime.add(DateTime.utc_now(), -80)

      steps = [
        %Wardrik.Chat.Step{
          id: "s1",
          title: "Running search",
          status: :failed,
          details: "Timed out.",
          since: since
        },
        %Wardrik.Chat.Step{
          id: "s2",
          title: "Thinking",
          status: :running,
          details: "Checking the calendar.",
          shown: 9,
          since: since
        }
      ]

      assert progress(context.workspace, "stream:9.8", steps) == :ok

      assert_receive {:slack, "chat.appendStream",
                      %{
                        "ts" => "9.8",
                        "chunks" => [
                          %{"id" => "s1", "status" => "error", "details" => "Timed out."},
                          %{
                            "id" => "s2",
                            "title" => "Thinking · 1m 20s",
                            "details" => "the calendar."
                          }
                        ]
                      }},
                     1_000
    end

    test "sends no more details once the message holds its share", context do
      step = %Wardrik.Chat.Step{
        id: "s1",
        title: "Thinking",
        status: :running,
        details: String.duplicate("a", 8_000) <> "more",
        shown: 8_000,
        since: DateTime.utc_now()
      }

      assert progress(context.workspace, "stream:9.8", [step]) == :ok
      assert_receive {:slack, "chat.appendStream", %{"chunks" => [task]}}, 1_000
      refute Map.has_key?(task, "details")
    end

    test "moves to a message it edits once the stream has ended", context do
      steps = [
        %Wardrik.Chat.Step{
          id: "s1",
          title: "Thinking",
          status: :running,
          since: DateTime.utc_now()
        }
      ]

      assert progress(context.workspace, "stream:9.7", steps) == {:ok, "message:9.9"}

      assert_receive {:slack, "chat.postMessage", %{"thread_ts" => "1.1", "text" => "Working…"}},
                     1_000

      assert progress(context.workspace, "message:9.9", steps) == :ok
      assert_receive {:slack, "chat.update", %{"ts" => "9.9"}}, 1_000
    end

    test "posts the reply on its own once the stream has ended", context do
      outbound = %Wardrik.Chat.Outbound{
        installation: context.workspace.installation,
        room: "C1",
        thread: "1.1",
        body: {:reply, "Done.", ["1.1"]},
        progress: "stream:9.7"
      }

      assert WardrikSlack.deliver(outbound, context.channel) == :ok

      assert_receive {:slack, "chat.postMessage", %{"thread_ts" => "1.1", "text" => "Done."}},
                     1_000
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

    test "names the agent, with its ID in small text, and carries the notice as metadata",
         context do
      notice = %Wardrik.Notice{
        agent: "agt_digest",
        name: "digest",
        conversation: "daily",
        kind: :failed,
        at: ~U[2026-11-19 10:00:00Z],
        reason: "It timed out."
      }

      notification = %Wardrik.Channel.Notification{workspace: "T1", room: "#news", notice: notice}
      assert WardrikSlack.notify(notification, context.options) == :ok

      assert_receive {:slack, "chat.postMessage", posted}, 1_000
      assert posted["text"] == ":warning: *digest* stopped with an error: It timed out."
      assert %{"elements" => [%{"text" => "`agt_digest`"}]} = List.last(posted["blocks"])

      assert posted["metadata"] == %{
               "event_type" => "turn_failed",
               "event_payload" => %{
                 "event" => "turn_failed",
                 "agent" => "agt_digest",
                 "name" => "digest",
                 "conversation" => "daily",
                 "at" => "2026-11-19T10:00:00Z",
                 "calls" => [],
                 "reason" => "It timed out."
               }
             }
    end

    test "posts no notice of a turn in one of its threads, which shows it", context do
      channel = Wardrik.Chat.channel(WardrikSlack, context.options)
      {:ok, workspace} = Wardrik.Chat.workspace(channel, "T1")

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
        build_press("wardrik_approve", %{value: approve["value"]}, "U1",
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

defmodule WardrikSlackTest.Home do
  @moduledoc "Greets the member above the default page, as your app's own Home tab might."

  @behaviour WardrikSlack.Home

  @impl WardrikSlack.Home
  def blocks(%WardrikSlack.Home.Request{member: member} = request, opts) do
    [WardrikSlack.Blocks.section("#{opts[:greeting]}, #{member.id}")] ++
      WardrikSlack.Home.Agents.blocks(request, [])
  end
end
