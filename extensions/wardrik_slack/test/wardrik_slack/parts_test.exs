defmodule WardrikSlack.PartsTest do
  use ExUnit.Case, async: false

  import WardrikSlack.Test

  alias Wardrik.Chat.Offer
  alias Wardrik.Chat.Waiting
  alias WardrikSlack.Dispatch
  alias WardrikSlack.Rooms

  setup :start_slack

  defp waiting(reason, name),
    do: %Waiting{
      agent: "agt_triage",
      conversation: "slack.T1.C1.1.1",
      interrupt: %Wardrik.Interrupt{
        id: "call_1",
        reason: reason,
        message: "Go?",
        name: name,
        labels: ["outside"]
      },
      arguments: %{"to" => "ops"}
    }

  describe "waiting calls" do
    test "say what they wait on" do
      assert %{text: "Waiting for someone to approve `echo`."} =
               WardrikSlack.Waiting.message([waiting(:tool_approval, "echo")])

      assert %{text: "Waiting for someone to approve `the model`."} =
               WardrikSlack.Waiting.message([waiting(:model_approval, nil)])

      assert %{text: "Waiting for someone to sign in for `inbox`.", blocks: blocks} =
               WardrikSlack.Waiting.message([waiting(:authorization, "inbox")])

      encoded = JSON.encode!(blocks)
      assert encoded =~ "Show link"
      assert encoded =~ "content from outside"
      refute encoded =~ "wardrik-note:"
    end
  end

  describe "members" do
    test "carry the email address Slack holds, unless they're from another workspace", context do
      {:ok, workspace} = Wardrik.Chat.workspace(context.channel, "T1")

      assert %Wardrik.Chat.Member{id: "U1", name: "maria", email: "maria@acme.com"} =
               WardrikSlack.Messages.sender(workspace, "U1")

      assert %Wardrik.Chat.Member{id: "U8", email: nil} =
               WardrikSlack.Messages.sender(workspace, "U8")
    end
  end

  describe "rooms" do
    test "offer a menu where there are many agents to pick from", context do
      for n <- 1..6, do: define(context.owner, "agt_#{n}", channels: ["slack"])
      {:ok, workspace} = Wardrik.Chat.workspace(context.channel, "T1")

      assert %{blocks: [_question, %{elements: [%{type: "static_select", options: options}]}]} =
               Rooms.message(Wardrik.Chat.Rooms.choices(workspace), workspace, nil)

      assert Enum.count(options) == 6
    end

    test "say how the agent answers", context do
      define(context.owner, "agt_triage", channels: ["slack"])
      {:ok, workspace} = Wardrik.Chat.workspace(context.channel, "T1")
      {:bound, binding, offer} = Wardrik.Chat.Rooms.joined(workspace, "C1")

      assert JSON.encode!(Rooms.message({:bound, binding, offer}, workspace, nil)) =~
               "Mention the app"

      assert JSON.encode!(Rooms.message({:bound, binding, offer}, workspace, "UBOT")) =~
               "someone who may decide it"
    end

    test "show an agent by its display name, or else its ID" do
      assert Rooms.shown(%Offer{agent: "agt_triage", name: "Triage"}) == "Triage"
      assert Rooms.shown(%Offer{agent: "agt_triage", name: ""}) == "agt_triage"
      assert Rooms.shown(%Offer{agent: "agt_triage"}) == "agt_triage"
    end

    test "offer nothing to a member your app doesn't know", context do
      define(context.owner, "agt_triage", channels: ["slack"])

      event(context, %{type: "member_joined_channel", user: "UBOT", channel: "C1", inviter: "U9"})

      assert_receive {:slack, "chat.postMessage", %{"text" => "No agent answers here yet." <> _}},
                     1_000
    end

    test "answer a press in a room no agent answers in", context do
      press(context, %{
        user: %{id: "U1"},
        channel: %{id: "C1"},
        response_url: "https://hooks.slack.com/actions/1",
        actions: [%{action_id: "wardrik_room_answers", value: "mentions"}]
      })

      assert_receive {:slack, {:respond, _path}, %{"text" => "No agent answers here yet." <> _}},
                     1_000

      press(context, %{
        user: %{id: "U1"},
        channel: %{id: "C1"},
        response_url: "https://hooks.slack.com/actions/1",
        actions: [%{action_id: "wardrik_room_agent", value: "agt_nobody"}]
      })

      assert_receive {:slack, {:respond, _path},
                      %{"text" => "That agent isn't offered here anymore."}},
                     1_000
    end
  end

  describe "dispatch" do
    test "leaves what it can't place", %{channel: channel} do
      assert Dispatch.event(channel, %{"type" => "event_callback"}) == :ignored
      assert Dispatch.interactive(channel, %{"type" => "view_submission"}) == :ignored

      assert Dispatch.event(channel, %{
               "team_id" => "T1",
               "event" => %{"type" => "reaction_added"}
             }) == :ignored
    end

    @tag slack: [token: nil, installations: :stored]
    test "leaves a workspace the app isn't added to", %{channel: channel} do
      event = %{"team_id" => "T9", "event" => %{"type" => "message"}}
      assert Dispatch.event(channel, event) == :ignored
    end
  end
end
