defmodule Wardrik.Slack.PartsTest do
  use ExUnit.Case, async: false

  defp membership(installation, names, member),
    do: %WardrikChannel.Membership{installation: installation, names: names, member: member}

  use Mimic

  import Wardrik.Test.Slack

  alias WardrikChannel.Member
  alias WardrikChannel.Waiting
  alias WardrikSlack.Dispatch
  alias WardrikSlack.Rooms

  setup :set_mimic_global
  setup :start_wardrik

  defp waiting(reason, name),
    do: %Waiting{
      conversation: "acme/triage/slack.T1.C1.1.1",
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
    test "say who may decide, and what" do
      assert %{text: "Anyone here may approve `echo`."} =
               WardrikSlack.Waiting.message([waiting(:tool_approval, "echo")], :anyone)

      assert %{text: "Waiting on whoever asked to approve `the model`."} =
               WardrikSlack.Waiting.message([waiting(:model_approval, nil)], [])

      assert %{
               text: "Waiting on @maria, ana@example.com or <@U9> to sign in for `inbox`.",
               blocks: blocks
             } =
               WardrikSlack.Waiting.message([waiting(:authorization, "inbox")], [
                 "@maria",
                 "ana@example.com",
                 "U9"
               ])

      encoded = JSON.encode!(blocks)
      assert encoded =~ "Show link"
      assert encoded =~ "content from outside"
      refute encoded =~ "wardrik-note:"
    end
  end

  describe "approvers" do
    test "are found by member ID, handle or email address", %{channel: channel} do
      {:ok, workspace} = WardrikChannel.workspace(channel, "T1")
      installation = workspace.installation
      maria = %Member{id: "U1"}

      assert WardrikSlack.include?(membership(installation, ["U1"], maria), channel)
      assert WardrikSlack.include?(membership(installation, ["@maria"], maria), channel)

      assert WardrikSlack.include?(
               membership(installation, ["maria@example.com"], maria),
               channel
             )

      refute WardrikSlack.include?(membership(installation, ["@jon"], maria), channel)
    end
  end

  describe "rooms" do
    test "offer a menu where there are many agents to pick from", context do
      for n <- 1..6, do: define(context.owner, "acme/agent-#{n}", channels: ["slack"])
      {:ok, workspace} = WardrikChannel.workspace(context.channel, "T1")

      assert %{blocks: [_question, %{elements: [%{type: "static_select", options: options}]}]} =
               Rooms.message(WardrikChannel.Rooms.choices(workspace), workspace, nil)

      assert Enum.count(options) == 6
    end

    test "say how the agent answers", context do
      define(context.owner, "acme/triage", channels: ["slack"])
      {:ok, workspace} = WardrikChannel.workspace(context.channel, "T1")
      {:bound, binding, offer} = WardrikChannel.Rooms.joined(workspace, "C1")

      assert JSON.encode!(Rooms.message({:bound, binding, offer}, workspace, nil)) =~
               "Mention the app"

      anyone = put_in(workspace.installation.approvers, :anyone)

      assert JSON.encode!(Rooms.message({:bound, binding, offer}, anyone, "UBOT")) =~
               "Anyone here"

      nobody = put_in(workspace.installation.approvers, [])

      assert JSON.encode!(Rooms.message({:bound, binding, offer}, nobody, "UBOT")) =~
               "whoever asked"
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
        actions: [%{action_id: "wardrik_room_agent", value: "acme/nobody"}]
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
