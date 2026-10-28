defmodule Wardrik.Channel.PackageTest do
  use ExUnit.Case, async: false
  use Mimic

  import Wardrik.Test.Channel

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
      assert actor == %{"id" => "chat:T1/U1", "name" => "maria"}
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
               Rooms.chose(context.workspace, "C1", "acme/two")

      assert Rooms.chose(context.workspace, "C1", "acme/@jon/mine") == {:error, :not_offered}
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

      assert {:asked, "acme/triage/chat.T1.C1.1.1"} =
               WardrikChannel.received(context.workspace, mention("Hi", "1.1"))

      assert_receive {:delivered, %Outbound{thread: "1.1", body: {:reply, "Hello.", ["1.1"]}}},
                     1_000

      assert {:asked, "acme/triage/chat.T1.C1.1.1"} =
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

      scope = Wardrik.as(context.wardrik, "acme/@maria", roles: [:messenger], resources: ["*"])
      {:ok, _message} = Wardrik.Agent.ask(scope, "acme/triage/chat.T1.C1.1.1", "More")

      assert WardrikChannel.Replies.follow(context.workspace, "C1") == :ok
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
      assert WardrikChannel.Replies.remind(context.workspace, "C9", "acme/triage/chat.T1.C9.1") ==
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

      assert_receive {:delivered,
                      %Outbound{approvers: ["@maria"], body: {:waiting, [%Waiting{} = waiting]}}},
                     1_000

      %{waiting: waiting}
    end

    test "posts a waiting call with its arguments, and who asked", %{waiting: waiting} do
      assert %Waiting{
               conversation: "acme/triage/chat.T1.C1.1.1",
               interrupt: %Wardrik.Interrupt{id: "call_1", name: "echo"},
               arguments: %{"text" => "hi"},
               asked_by: "chat:T1/U3"
             } = waiting
    end

    test "lets an approver decide, and says who did", context do
      button = %{conversation: context.waiting.conversation, interrupt: "call_1"}

      assert {:ok, %Wardrik.Decision{decision: :approved}} =
               WardrikChannel.decide(context.workspace, @maria, button, {:approve, nil})

      assert_receive {:delivered, %Outbound{body: {:said, "Approved by maria."}}}, 1_000
      assert_receive {:delivered, %Outbound{body: {:reply, "Done.", ["1.1"]}}}, 1_000
    end

    test "lets whoever asked decide, and nobody else", context do
      %Waiting{conversation: conversation, asked_by: asked_by} = context.waiting
      button = %{conversation: conversation, interrupt: "call_1", asked_by: asked_by}

      assert WardrikChannel.decide(context.workspace, @jon, button, {:deny, nil}) ==
               {:error, context.channel.deciding}

      assert {:ok, %Wardrik.Decision{decision: :rejected}} =
               WardrikChannel.decide(context.workspace, @ana, button, {:deny, "Not now."})

      assert_receive {:delivered, %Outbound{body: {:said, "Denied by ana: Not now."}}}, 1_000
    end

    test "says a run stopped before it answered", context do
      Wardrik.Agent.cancel(context.owner, context.waiting.conversation)

      assert_receive {:delivered, %Outbound{body: {:stopped, ["1.1"]}}}, 1_000
    end

    test "posts the waiting call again for a message behind it", context do
      assert {:asked, _conversation} =
               WardrikChannel.received(context.workspace, reply("Well?", "1.1", "1.2"))

      assert_receive {:delivered,
                      %Outbound{body: {:waiting, [%Waiting{asked_by: "chat:T1/U3"}]}}},
                     1_000
    end
  end

  describe "approvers" do
    test "are the people named, anyone, or nobody", %{workspace: workspace} do
      assert WardrikChannel.Workspace.approver?(workspace, @maria)
      refute WardrikChannel.Workspace.approver?(workspace, @jon)

      anyone = put_in(workspace.installation.approvers, :anyone)
      assert WardrikChannel.Workspace.approver?(anyone, @jon)

      nobody = put_in(workspace.installation.approvers, [])
      refute WardrikChannel.Workspace.approver?(nobody, @maria)
    end
  end

  describe "channels" do
    test "is named in lower-case letters, digits and -, and says where it's added" do
      assert_raise ArgumentError, ~r/lower-case/, fn ->
        WardrikChannel.channel(Wardrik.Test.Channel.Chat, channel: "Chat", token: "t")
      end

      assert_raise ArgumentError, ~r/token/, fn ->
        WardrikChannel.channel(Wardrik.Test.Channel.Chat,
          channel: "chat",
          wardrik: :w,
          store: nil
        )
      end
    end

    test "is added with its token alone", %{channel: channel} do
      {module, config} = channel.installations
      {:ok, installation} = WardrikChannel.Channel.installation(channel, "T9")

      assert installation.owner == "acme"
      refute inspect(installation) =~ "xoxb"
      assert {:error, _why} = module.put(config, installation)
      assert module.delete(config, "chat", "T9") == :ok
    end

    test "answers what the chat app sends through the Wardrik", %{wardrik: wardrik} do
      scope = Wardrik.as(wardrik, "anonymous")

      assert {:ok, %Wardrik.ChannelResponse{status: 200, body: "{}"}} =
               Wardrik.Channel.deliver(scope, "chat", "events", body: "{}", headers: %{})
    end
  end

  describe "notices" do
    test "posts a notice in the room itself, through the owner's workspace", context do
      notice = %Wardrik.Notice{
        agent: "acme/digest",
        kind: :finished,
        at: DateTime.utc_now(),
        text: "Done."
      }

      {:ok, {adapter, opts}} = Wardrik.Operations.Channels.fetch(context.wardrik, "chat")

      assert adapter.notify(opts, "#news", notice, ["@maria"]) == :ok

      assert_receive {:delivered,
                      %Outbound{
                        room: "#news",
                        thread: nil,
                        body: {:notice, ^notice},
                        approvers: ["@maria"]
                      } =
                        outbound}

      assert outbound.installation.owner == "acme"

      assert {:skip, _why} = adapter.notify(opts, "#news", %{notice | agent: "globex/digest"}, [])
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
                 conversation: "acme/triage",
                 interrupt: interrupt,
                 arguments: %{"text" => "hi"}
               }
             ]
    end
  end
end
