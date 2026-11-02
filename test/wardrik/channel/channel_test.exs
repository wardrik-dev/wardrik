defmodule Wardrik.Channel.PackageTest do
  use ExUnit.Case, async: false
  use Mimic

  import Wardrik.Test.Channel

  alias WardrikChannel.Answer
  alias WardrikChannel.Binding
  alias WardrikChannel.Inbound
  alias WardrikChannel.Member
  alias WardrikChannel.Offer
  alias WardrikChannel.Outbound
  alias WardrikChannel.Rooms
  alias WardrikChannel.Waiting

  setup :set_mimic_global
  setup :start_wardrik

  @maria %Member{id: "U1", name: "maria"}
  @jon %Member{id: "U2", name: "jon"}
  @ana %Member{id: "U3", name: "ana"}

  defp mention(text, id, sender \\ @ana),
    do: %Inbound{room: "C1", id: id, sender: sender, text: text, mentioned?: true}

  defp reply(text, thread, id, sender \\ @ana),
    do: %Inbound{room: "C1", thread: thread, id: id, sender: sender, text: text}

  defp audited(owner) do
    {:ok, page} = Wardrik.Audit.list(owner)
    for event <- page.events, String.starts_with?(event.type, "wardrik.room."), do: event
  end

  describe "rooms" do
    test "binds a room to the one agent offered, and records who did", context do
      define(context.owner, "acme/triage", channels: ["chat"], description: "Triages.")
      define(context.owner, "acme/quiet")

      assert {:bound, %Binding{agent: "acme/triage", answers: :mentions},
              %Offer{agent: "acme/triage", description: "Triages."}} =
               Rooms.joined(context.workspace, "C1", @maria)

      assert %Binding{agent: "acme/triage"} = Rooms.get(context.workspace, "C1")

      assert [%Wardrik.Event{type: "wardrik.room.bound", data: data}] = audited(context.owner)
      assert %{"room" => "C1", "agent" => %{"id" => "acme/triage"}, "actor" => actor} = data
      assert actor == %{"id" => "acme/@maria", "name" => "maria"}
    end

    test "offers a choice of several, and nothing where none is offered", context do
      assert Rooms.joined(context.workspace, "C1") == :none
      assert Rooms.choices(context.workspace) == :none

      define(context.owner, "acme/one", channels: ["chat"])
      define(context.owner, "acme/two", channels: ["chat"])
      define(context.owner, "acme/@jon/mine", channels: ["chat"])

      assert {:choose, [%Offer{agent: "acme/one"}, %Offer{agent: "acme/two"}]} =
               Rooms.joined(context.workspace, "C1")

      assert {:ok, %Binding{agent: "acme/two"}, %Offer{}} =
               Rooms.chose(context.workspace, room: "C1", agent: "acme/two")

      assert Rooms.chose(context.workspace, room: "C1", agent: "acme/@jon/mine") ==
               {:error, :not_offered}
    end

    test "unbinds a room the bot leaves", context do
      define(context.owner, "acme/triage", channels: ["chat"])
      Rooms.joined(context.workspace, "C1")

      assert Rooms.left(context.workspace, "C1", @maria) == :ok
      assert Rooms.get(context.workspace, "C1") == nil
      assert WardrikChannel.received(context.workspace, mention("Hi", "1.1")) == :ignored
      assert Rooms.left(context.workspace, "C1") == :ok

      assert ["wardrik.room.bound", "wardrik.room.unbound"] =
               Enum.map(audited(context.owner), & &1.type)
    end

    test "has the agent answer every message, or only mentions", context do
      assert Rooms.answers(context.workspace, "C1", :everything) == {:error, :not_bound}

      define(context.owner, "acme/triage", channels: ["chat"])
      Rooms.joined(context.workspace, "C1")

      assert {:ok, %Binding{answers: :everything}} =
               Rooms.answers(context.workspace, "C1", :everything)

      answers([answer("Heard.")])

      assert {:asked, _conversation} =
               WardrikChannel.received(context.workspace, %{
                 mention("Hi", "1.1")
                 | mentioned?: false
               })
    end
  end

  describe "threads" do
    setup context do
      define(context.owner, "acme/triage", channels: ["chat"])
      Rooms.joined(context.workspace, "C1")
      :ok
    end

    test "answers a mention in a thread of its own, and replies in it after", context do
      answers([answer("Hello."), answer("Again.")])

      assert {:asked, {"acme/triage", "chat.T1.C1.1.1"}} =
               WardrikChannel.received(context.workspace, mention("Hi", "1.1"))

      assert_receive {:delivered, %Outbound{thread: "1.1", body: {:reply, "Hello.", ["1.1"]}}},
                     1_000

      assert {:asked, {"acme/triage", "chat.T1.C1.1.1"}} =
               WardrikChannel.received(context.workspace, reply("More", "1.1", "1.2"))

      assert_receive {:delivered, %Outbound{thread: "1.1", body: {:reply, "Again.", ["1.2"]}}},
                     1_000
    end

    test "carries on from where it posted after the room's process stops", context do
      answers([answer("Hello."), answer("Again.")])
      WardrikChannel.received(context.workspace, mention("Hi", "1.1"))
      assert_receive {:delivered, %Outbound{body: {:reply, "Hello.", _answering}}}, 1_000

      replies = Module.concat([context.wardrik, "Channels", "chat", "Replies"])
      DurableServer.Supervisor.terminate_child(replies, "T1/C1")
      assert DurableServer.Supervisor.lookup(replies, "T1/C1") == nil

      scope = Wardrik.as(context.wardrik, "acme/@maria")

      {:ok, _message} =
        Wardrik.Agent.ask(scope, "acme/triage", content: "More", conversation: "chat.T1.C1.1.1")

      assert WardrikChannel.Replies.follow(context.workspace,
               room: "C1",
               agent: "acme/triage",
               conversation: "chat.T1.C1.1.1"
             ) == :ok

      assert_receive {:delivered, %Outbound{body: {:reply, "Again.", _answering}}}, 1_000
      refute_received {:delivered, %Outbound{body: {:reply, "Hello.", _answering}}}
    end

    test "tries a post again that the chat app refused", context do
      answers([answer("Hello.")])
      :counters.put(context.refusals, 1, 1)
      WardrikChannel.received(context.workspace, mention("Hi", "1.1"))

      assert_receive {:refused, %Outbound{}}, 1_000
      assert_receive {:delivered, %Outbound{body: {:reply, "Hello.", ["1.1"]}}}, 3_000
    end

    test "says why a run failed", context do
      Mimic.stub(ReqLLM, :stream_text, fn _model, _messages, _opts ->
        {:error, %RuntimeError{message: "The model is down."}}
      end)

      WardrikChannel.received(context.workspace, mention("Hi", "1.1"))
      assert_receive {:delivered, %Outbound{body: {:failed, reason}}}, 5_000
      assert reason =~ "down"
    end

    test "reminds no room that isn't posting", context do
      assert WardrikChannel.Replies.remind(context.workspace,
               room: "C9",
               agent: "acme/triage",
               conversation: "chat.T1.C9.1"
             ) ==
               :ok
    end

    test "leaves alone what isn't for it", context do
      assert WardrikChannel.received(context.workspace, %{
               mention("Hi", "1.1")
               | mentioned?: false
             }) ==
               :ignored

      assert WardrikChannel.received(context.workspace, reply("Hi", "9.9", "9.10")) == :ignored

      assert WardrikChannel.received(context.workspace, %{mention("Hi", "1.1") | room: "C2"}) ==
               :ignored
    end

    test "shows what the agent is doing while it works", context do
      answers([answer("Hello.")])
      WardrikChannel.received(context.workspace, mention("Hi", "1.1"))

      assert_receive {:delivered, %Outbound{body: {:status, "is thinking…"}}}, 1_000
    end
  end

  describe "deciding" do
    setup context do
      define(context.owner, "acme/triage",
        channels: ["chat"],
        tools: ["tools"],
        policy: "careful"
      )

      Rooms.joined(context.workspace, "C1")
      answers([calling("call_1", "echo", %{"text" => "hi"}), answer("Done.")])
      WardrikChannel.received(context.workspace, mention("Echo hi", "1.1"))

      assert_receive {:delivered, %Outbound{body: {:waiting, [%Waiting{} = waiting]}}}, 1_000

      %{waiting: waiting}
    end

    test "posts a waiting call with its arguments, and who asked", %{waiting: waiting} do
      assert %Waiting{
               agent: "acme/triage",
               conversation: "chat.T1.C1.1.1",
               interrupt: %Wardrik.Interrupt{id: "call_1", name: "echo"},
               arguments: %{"text" => "hi"},
               asked_by: "acme/@ana"
             } = waiting
    end

    test "lets a member whose own binding allows it decide, and says who did", context do
      answer = %Answer{
        member: @maria,
        agent: context.waiting.agent,
        conversation: context.waiting.conversation,
        interrupt: "call_1",
        decision: {:approve, nil}
      }

      assert {:ok, %Wardrik.Decision{decision: :approved}} =
               WardrikChannel.decide(context.workspace, answer)

      assert_receive {:delivered, %Outbound{body: {:said, "Approved by maria."}}}, 1_000
      assert_receive {:delivered, %Outbound{body: {:reply, "Done.", ["1.1"]}}}, 1_000
    end

    test "lets whoever asked decide, and nobody else", context do
      %Waiting{agent: agent, conversation: conversation, asked_by: asked_by} = context.waiting

      answer = %Answer{
        member: @jon,
        agent: agent,
        conversation: conversation,
        interrupt: "call_1",
        asked_by: asked_by,
        decision: {:deny, nil}
      }

      assert WardrikChannel.decide(context.workspace, answer) ==
               {:error, context.channel.deciding}

      assert {:ok, %Wardrik.Decision{decision: :rejected}} =
               WardrikChannel.decide(context.workspace, %{
                 answer
                 | member: @ana,
                   decision: {:deny, "Not now."}
               })

      assert_receive {:delivered, %Outbound{body: {:said, "Denied by ana: Not now."}}}, 1_000
    end

    test "says a run stopped before it answered", context do
      %Waiting{agent: agent, conversation: conversation} = context.waiting
      Wardrik.Agent.cancel(context.owner, agent, conversation: conversation)

      assert_receive {:delivered, %Outbound{body: {:stopped, ["1.1"]}}}, 1_000
    end

    test "posts the waiting call again for a message behind it", context do
      assert {:asked, _conversation} =
               WardrikChannel.received(context.workspace, reply("Well?", "1.1", "1.2"))

      assert_receive {:delivered, %Outbound{body: {:waiting, [%Waiting{asked_by: "acme/@ana"}]}}},
                     1_000
    end
  end

  describe "members your app doesn't know" do
    test "can't ask or decide, and are told why", context do
      define(context.owner, "acme/triage", channels: ["chat"])
      Rooms.joined(context.workspace, "C1")
      stranger = %Member{id: "U9", name: "stranger"}

      assert WardrikChannel.received(context.workspace, mention("Hi", "1.1", stranger)) ==
               {:error, "Nobody here knows you yet."}

      answer = %Answer{
        member: stranger,
        agent: "acme/triage",
        conversation: "chat.T1.C1.1.1",
        interrupt: "call_1",
        decision: {:approve, nil}
      }

      assert WardrikChannel.decide(context.workspace, answer) ==
               {:error, "Nobody here knows you yet."}
    end
  end

  describe "channels" do
    test "is named in lower-case letters, digits and -, and says where it's added" do
      passed = [
        server: Wardrik,
        wardrik: :w,
        events: :e,
        store: nil,
        identities: {Wardrik.Test.Channel.Members, members: %{}}
      ]

      assert_raise ArgumentError, ~r/lower-case/, fn ->
        WardrikChannel.channel(Wardrik.Test.Channel.Chat, [channel: "Chat", token: "t"] ++ passed)
      end

      assert_raise ArgumentError, ~r/token/, fn ->
        WardrikChannel.channel(Wardrik.Test.Channel.Chat, [channel: "chat"] ++ passed)
      end
    end

    test "is added with its token alone", %{channel: channel} do
      {module, config} = channel.installations
      {:ok, installation} = WardrikChannel.Channel.installation(channel, "T9")

      assert installation.owner == "acme"
      refute inspect(installation) =~ "xoxb"
      assert {:error, _why} = module.put(installation, config)

      assert module.delete(
               %Wardrik.Channel.Installations.Request{channel: "chat", workspace: "T9"},
               config
             ) == :ok
    end

    test "answers what the chat app sends through the Wardrik", %{wardrik: wardrik} do
      scope = Wardrik.as(wardrik, "anonymous")

      assert {:ok, %Wardrik.ChannelResponse{status: 200, body: "{}"}} =
               Wardrik.Channel.deliver(scope,
                 channel: "chat",
                 path: "events",
                 body: "{}",
                 headers: %{}
               )
    end
  end

  describe "notices" do
    test "posts a notice in the room itself, in the workspace the agent's resolver gives",
         context do
      notice = %Wardrik.Notice{
        agent: "acme/digest",
        kind: :finished,
        at: DateTime.utc_now(),
        text: "Done."
      }

      {:ok, {adapter, opts}} = Wardrik.Operations.Channels.fetch(context.wardrik, "chat")

      notification = %Wardrik.Channel.Notification{workspace: "T1", room: "#news", notice: notice}

      assert adapter.notify(notification, opts) == :ok

      assert_receive {:delivered,
                      %Outbound{room: "#news", thread: nil, body: {:notice, ^notice}} = outbound}

      assert outbound.installation.workspace == "T1"
    end

    test "reads a parked turn's calls from its notice" do
      interrupt = %Wardrik.Interrupt{id: "call_1", name: "echo"}

      notice = %Wardrik.Notice{
        agent: "acme/triage",
        kind: :parked,
        at: DateTime.utc_now(),
        calls: [%{interrupt: interrupt, arguments: %{"text" => "hi"}}]
      }

      assert Waiting.from_notice(notice) == [
               %Waiting{
                 agent: "acme/triage",
                 interrupt: interrupt,
                 arguments: %{"text" => "hi"}
               }
             ]
    end
  end
end
