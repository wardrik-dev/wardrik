defmodule WardrikSlack.RoomsTest do
  use ExUnit.Case, async: false

  alias Wardrik.AgentID
  alias Wardrik.Test.Audit
  alias WardrikChannel.Context
  alias WardrikSlack.Rooms

  @req_options [plug: {Req.Test, WardrikSlack.Stub}]

  setup do
    test = self()

    Req.Test.stub(WardrikSlack.Stub, fn conn ->
      send(test, {:slack, conn.request_path, JSON.decode!(Req.Test.raw_body(conn))})
      Req.Test.json(conn, %{ok: true})
    end)

    :ok
  end

  @doc false
  def offering(agents, _channel), do: agents

  defp opts(agents) do
    context = %Context{
      channel: "slack-#{System.unique_integer([:positive])}",
      offered: {__MODULE__, :offering, [agents]}
    }

    [context: context, bot: "UBOT", token: "xoxb-test", req_options: @req_options]
  end

  defp books, do: AgentID.parse!("acme/books")
  defp triage, do: AgentID.parse!("acme/triage")

  defp joined(room, inviter \\ "U1"),
    do: %{
      "type" => "member_joined_channel",
      "user" => "UBOT",
      "channel" => room,
      "inviter" => inviter
    }

  defp press(room, action, value) do
    %{
      "channel" => %{"id" => room},
      "user" => %{"id" => "U2", "username" => "jon"},
      "response_url" => "https://hooks.slack.com/actions/r",
      "actions" => [%{"action_id" => action, "value" => value}]
    }
  end

  test "binds the room to the one agent offered as the bot is invited, and says when it answers" do
    opts = opts([books()])

    assert :ok = Rooms.event(joined("C1"), opts)

    assert_receive {:slack, "/api/chat.postMessage", message}
    assert message["channel"] == "C1"
    assert message["text"] == "I'll answer here as *acme/books*, when mentioned."

    assert %{"elements" => [mentions, everything]} =
             Enum.find(message["blocks"], &(&1["type"] == "actions"))

    assert {mentions["value"], mentions["style"]} == {"mentions", "primary"}
    assert {everything["value"], everything["style"]} == {"everything", nil}

    assert Audit.about("rooms/#{opts[:context].channel}/C1") ==
             [{"room.bound", %{"type" => "slack", "id" => "U1"}}]
  end

  test "offers the agents to choose among, and binds the one pressed" do
    opts = opts([books(), triage()])
    assert :ok = Rooms.event(joined("C1"), opts)

    assert_receive {:slack, "/api/chat.postMessage",
                    %{"text" => "Which agent should answer here?"} = message}

    assert %{"elements" => buttons} = Enum.find(message["blocks"], &(&1["type"] == "actions"))
    assert Enum.map(buttons, & &1["value"]) == ["acme/books", "acme/triage"]

    assert :ok = Rooms.answer(press("C1", "wardrik_room_agent", "acme/triage"), opts)
    assert_receive {:slack, "/actions/r", %{"replace_original" => true, "text" => text}}
    assert text =~ "acme/triage"
    assert WardrikChannel.Rooms.get(opts[:context], "C1").agent == triage()

    assert [{"room.bound", %{"id" => "U2", "name" => "jon"}}] =
             Audit.about("rooms/#{opts[:context].channel}/C1")
  end

  test "offers a menu where there are many to choose among" do
    agents = for n <- 1..6, do: AgentID.parse!("acme/agent#{n}")
    assert :ok = Rooms.event(joined("C1"), opts(agents))

    assert_receive {:slack, _path, message}

    assert %{"elements" => [%{"type" => "static_select", "options" => options}]} =
             Enum.find(message["blocks"], &(&1["type"] == "actions"))

    assert [_, _, _, _, _, _] = options
  end

  test "says nothing where no agent is offered, as in a room it only posts notices in" do
    assert Rooms.event(joined("C1"), opts([])) == :ignored
    refute_received {:slack, _path, _message}
  end

  test "changes when the agent answers, and refuses an agent no longer offered" do
    opts = opts([books()])
    :ok = Rooms.event(joined("C1"), opts)
    assert_receive {:slack, _path, _message}

    assert :ok = Rooms.answer(press("C1", "wardrik_room_answers", "everything"), opts)

    assert_receive {:slack, "/actions/r",
                    %{"text" => "I'll answer here as *acme/books*, to every message."}}

    assert :ok = Rooms.answer(press("C1", "wardrik_room_agent", "acme/triage"), opts)
    assert_receive {:slack, "/actions/r", %{"response_type" => "ephemeral"}}

    assert :ok = Rooms.answer(press("C9", "wardrik_room_answers", "mentions"), opts)
    assert_receive {:slack, "/actions/r", %{"text" => "No agent answers here" <> _}}

    assert :ok = Rooms.answer(press("C1", "wardrik_room_agent", "not an id"), opts)
    assert_receive {:slack, "/actions/r", %{"text" => "That does not read as an agent."}}
  end

  test "unbinds the room as the bot is taken out, and passes over anyone else joining" do
    opts = opts([books()])
    :ok = Rooms.event(joined("C1"), opts)

    assert Rooms.event(%{joined("C1") | "user" => "U9"}, opts) == :ignored

    assert :ok =
             Rooms.event(%{"type" => "channel_left", "channel" => "C1", "actor_id" => "U3"}, opts)

    assert WardrikChannel.Rooms.get(opts[:context], "C1") == nil

    assert Rooms.event(%{"type" => "reaction_added"}, opts) == :ignored
    assert Rooms.answer(%{"actions" => []}, opts) == :ignored
  end
end
