defmodule WardrikSlack.RoomsTest do
  use ExUnit.Case, async: false

  alias Wardrik.AgentID
  alias Wardrik.Test.Audit
  alias WardrikChannel.Context
  alias WardrikChannel.Installations
  alias WardrikChannel.Offer
  alias WardrikChannel.Room
  alias WardrikChannel.Workspace
  alias WardrikSlack.Rooms

  @req_options [plug: {Req.Test, WardrikSlack.Stub}]

  setup do
    test = self()

    Req.Test.stub(WardrikSlack.Stub, fn conn ->
      body = JSON.decode!(Req.Test.raw_body(conn))
      send(test, {:slack, conn.request_path, body})

      case conn.request_path do
        "/api/conversations.info" -> Req.Test.json(conn, %{ok: true, channel: %{name: "books"}})
        _other -> Req.Test.json(conn, %{ok: true})
      end
    end)

    :ok
  end

  # The options a channel of its own is answered with, offering the agents
  # `offers` define in it, and creating agents in an org of its own where
  # `create?`.
  defp opts(offers, create? \\ false) do
    channel = "slack-#{System.unique_integer([:positive])}"
    org = "made-#{System.unique_integer([:positive])}"
    on_exit(fn -> Wardrik.Fleet.forget_under(Wardrik.Resource.parse!(org <> "/*")) end)
    {:ok, careful} = WardrikPolicy.decode(%{"ask" => ["*"]})
    defaults = %{"model" => "anthropic:claude-sonnet-5", "policy" => "careful"}

    host =
      WardrikSlack.Test.host(
        policies: %{"careful" => careful},
        defaults: if(create?, do: defaults, else: %{})
      )

    for offer <- offers,
        do:
          WardrikSlack.Test.define(host, offer.agent, %{
            "channels" => [channel],
            "description" => offer.description
          })

    context = %Context{
      host: host,
      channel: channel,
      org: org,
      installations: Installations.Config.new([])
    }

    workspace = %Workspace{
      context: context,
      installation: %{WardrikSlack.Test.installation() | channel: channel}
    }

    [workspace: workspace, bot: "UBOT", token: "xoxb-test", req_options: @req_options]
  end

  defp channel(opts), do: opts[:workspace].context.channel
  defp person(opts, user), do: "#{channel(opts)}/T1/#{user}"

  defp with_context(opts, change),
    do: Keyword.update!(opts, :workspace, &%{&1 | context: change.(&1.context)})

  defp books, do: %Offer{agent: AgentID.parse!("acme/books"), description: "Keeps the books."}
  defp triage, do: %Offer{agent: AgentID.parse!("acme/triage")}

  defp joined(room, inviter \\ "U1"),
    do: %{
      "type" => "member_joined_channel",
      "user" => "UBOT",
      "channel" => room,
      "inviter" => inviter
    }

  defp press(room, action, value) do
    %{
      "channel" => %{"id" => room, "name" => "books"},
      "user" => %{"id" => "U2", "username" => "jon"},
      "response_url" => "https://hooks.slack.com/actions/r",
      "actions" => [%{"action_id" => action, "value" => value}]
    }
  end

  defp choose(room, action, value) do
    chosen = %{"action_id" => action, "selected_option" => %{"value" => value}}
    %{press(room, action, nil) | "actions" => [chosen]}
  end

  defp posted do
    assert_receive {:slack, "/api/chat.postMessage", message}
    message
  end

  defp replaced do
    assert_receive {:slack, "/actions/r", message}
    message
  end

  defp buttons(message) do
    message["blocks"]
    |> Enum.filter(&(&1["type"] == "actions"))
    |> Enum.flat_map(& &1["elements"])
    |> Enum.map(&(&1["value"] || &1["action_id"]))
  end

  test "binds the one agent offered at once, and says what it is and how to reach it" do
    opts = opts([books()])

    assert :ok = Rooms.event(joined("C1"), opts)

    message = posted()
    assert message["channel"] == "C1"
    assert message["text"] == ":wave: *acme/books* answers here now."
    text = JSON.encode!(message["blocks"])
    assert text =~ "Keeps the books."
    assert text =~ "Mention <@UBOT> and it answers in a thread under your message."
    assert text =~ "waits here for someone to approve it."
    assert buttons(message) == ["everything", "wardrik_room_more"]

    assert Audit.about("rooms/#{channel(opts)}/C1") ==
             [{"room.bound", %{"type" => "channel", "id" => person(opts, "U1")}}]
  end

  test "says who approves, where the channel names approvers" do
    opts = opts([books()])

    opts =
      with_context(
        opts,
        &%{&1 | approvers: %WardrikChannel.Approvers.Named{names: ["@maria", "U5"]}}
      )

    assert :ok = Rooms.event(joined("C1"), opts)

    assert JSON.encode!(posted()["blocks"]) =~
             "A call that needs approval is sent to @maria or <@U5> to approve"
  end

  test "offers each agent with what it is for, and binds the one used" do
    opts = opts([books(), triage()])
    assert :ok = Rooms.event(joined("C1"), opts)

    message = posted()
    assert message["text"] =~ "Which agent should answer here?"
    [_question, first | _] = message["blocks"]
    assert first["text"]["text"] == "*acme/books*\nKeeps the books."
    assert first["accessory"]["value"] == "acme/books"

    assert :ok = Rooms.answer(press("C1", "wardrik_room_agent", "acme/triage"), opts)

    assert %{"replace_original" => true, "text" => ":wave: *acme/triage* answers here now."} =
             replaced()

    assert WardrikChannel.Rooms.get(Room.new(opts[:workspace], "C1")).agent == triage().agent

    jon = person(opts, "U2")

    assert [{"room.bound", %{"id" => ^jon, "name" => "jon"}}] =
             Audit.about("rooms/#{channel(opts)}/C1")
  end

  test "names each agent as a workspace installed for an org reads it, its value whole" do
    org =
      Keyword.update!(
        opts([books(), triage()]),
        :workspace,
        &put_in(&1.installation.owner, Wardrik.Resource.parse!("acme"))
      )

    assert :ok = Rooms.event(joined("C1"), org)
    [_question, first | _] = posted()["blocks"]
    assert first["text"]["text"] == "*books*\nKeeps the books."
    assert first["accessory"]["value"] == "acme/books"

    assert :ok = Rooms.answer(press("C1", "wardrik_room_agent", "acme/triage"), org)
    assert %{"text" => ":wave: *triage* answers here now."} = replaced()
  end

  test "offers a menu, with what each is for, where there are many" do
    offers =
      for n <- 1..6, do: %Offer{agent: AgentID.parse!("acme/agent#{n}"), description: "No. #{n}"}

    assert :ok = Rooms.event(joined("C1"), opts(offers))

    assert %{"elements" => [%{"type" => "static_select", "options" => [first | _] = options}]} =
             Enum.find(posted()["blocks"], &(&1["type"] == "actions"))

    assert [_, _, _, _, _, _] = options
    assert first["description"]["text"] == "No. 1"
  end

  test "offers to create an agent for the room where none is offered, and creates it" do
    opts = opts([], true)
    assert :ok = Rooms.event(joined("C1"), opts)

    message = posted()
    assert message["text"] == "No agent answers in Slack here yet."
    assert buttons(message) == ["books"]
    assert JSON.encode!(message["blocks"]) =~ "Whoever runs Wardrik can offer an agent here"

    assert :ok = Rooms.answer(press("C1", "wardrik_room_create", "books"), opts)
    org = opts[:workspace].context.org
    assert %{"text" => ":wave: *" <> ^org <> "/books* answers here now."} = replaced()
  end

  test "says who can offer an agent where none may be created, and looks again" do
    opts = opts([])
    assert :ok = Rooms.event(joined("C1"), opts)

    message = posted()

    assert message["text"] ==
             "No agent answers in Slack here yet. Whoever runs Wardrik can offer an agent here " <>
               "by adding `channels: [#{channel(opts)}]` to its definition."

    assert buttons(message) == ["choose"]

    assert :ok = Rooms.answer(press("C1", "wardrik_room_more", "choose"), opts)
    assert %{"text" => "No agent answers in Slack here yet." <> _} = replaced()

    assert :ok = Rooms.answer(press("C1", "wardrik_room_create", "books"), opts)

    assert %{"response_type" => "ephemeral", "text" => "Agents are not created from here" <> _} =
             replaced()
  end

  test "switches between every message and mentions, offers another agent, and stops" do
    opts = opts([books(), triage()])

    {:ok, _room, _offer} =
      WardrikChannel.Rooms.chose(Room.new(opts[:workspace], "C1"), books().agent)

    assert :ok = Rooms.answer(press("C1", "wardrik_room_answers", "everything"), opts)
    message = replaced()
    assert JSON.encode!(message["blocks"]) =~ "It answers every message here"
    assert buttons(message) == ["mentions", "wardrik_room_more"]

    assert :ok = Rooms.answer(choose("C1", "wardrik_room_more", "choose"), opts)
    assert %{"text" => "Which agent should answer here?" <> _} = replaced()

    assert :ok = Rooms.answer(choose("C1", "wardrik_room_more", "stop"), opts)
    assert %{"text" => "No agent answers here now."} = replaced()
    assert WardrikChannel.Rooms.get(Room.new(opts[:workspace], "C1")) == nil

    assert :ok = Rooms.answer(press("C1", "wardrik_room_answers", "mentions"), opts)
    assert %{"text" => "Which agent should answer here?" <> _} = replaced()
  end

  test "refuses an agent no longer offered, and what does not read as one" do
    opts = opts([books()])

    assert :ok = Rooms.answer(press("C1", "wardrik_room_agent", "acme/triage"), opts)

    assert %{"response_type" => "ephemeral", "text" => "That agent is no longer offered here."} =
             replaced()

    assert :ok = Rooms.answer(press("C1", "wardrik_room_agent", "not an id"), opts)
    assert %{"text" => "That does not read as an agent."} = replaced()
  end

  test "unbinds the room as the bot is taken out, and passes over anyone else joining" do
    opts = opts([books()])
    :ok = Rooms.event(joined("C1"), opts)

    assert Rooms.event(%{joined("C1") | "user" => "U9"}, opts) == :ignored

    assert :ok =
             Rooms.event(%{"type" => "channel_left", "channel" => "C1", "actor_id" => "U3"}, opts)

    assert WardrikChannel.Rooms.get(Room.new(opts[:workspace], "C1")) == nil

    assert Rooms.event(%{"type" => "reaction_added"}, opts) == :ignored
    assert Rooms.answer(%{"actions" => []}, opts) == :ignored
  end
end
