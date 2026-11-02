defmodule WardrikChannelTest do
  use ExUnit.Case, async: true

  import WardrikChannel.Test

  alias Wardrik.Channel.Installation
  alias WardrikChannel.Answer
  alias WardrikChannel.Binding
  alias WardrikChannel.Channel
  alias WardrikChannel.Inbound
  alias WardrikChannel.Member
  alias WardrikChannel.Offer
  alias WardrikChannel.Outbound
  alias WardrikChannel.Rooms
  alias WardrikChannel.Waiting
  alias WardrikChannel.Workspace

  setup :start_channel

  @maria %Member{id: "U1", name: "maria"}
  @jon %Member{id: "U2", name: "jon"}
  @ana %Member{id: "U3", name: "ana"}

  defp mention(text, id, sender \\ @ana),
    do: %Inbound{room: "C1", id: id, sender: sender, text: text, mentioned?: true}

  defp reply(text, thread, id, sender \\ @ana),
    do: %Inbound{room: "C1", thread: thread, id: id, sender: sender, text: text}

  defp audited(context) do
    %{events: events} = WardrikEvents.audit(context.events)
    for %{"type" => "wardrik.room." <> _rest} = event <- events, do: event
  end

  defp conversation(context, thread),
    do: "acme/triage/#{context.channel.name}.T1.C1.#{thread}"

  describe "rooms" do
    test "binds a room to the one agent offered, and records who did", context do
      assert {:bound, %Binding{agent: "acme/triage", answers: :mentions},
              %Offer{agent: "acme/triage", description: "Answers acme/triage."}} =
               Rooms.joined(context.workspace, "C1", @maria)

      assert %Binding{agent: "acme/triage"} = Rooms.get(context.workspace, "C1")

      assert [%{"type" => "wardrik.room.bound", "data" => data}] = audited(context)
      assert %{"room" => "C1", "agent" => %{"id" => "acme/triage"}, "actor" => actor} = data
      assert actor["id"] == "#{context.channel.name}:T1/U1"
    end

    @tag offered: []
    test "offers nothing where no agent answers in it", context do
      assert Rooms.joined(context.workspace, "C1") == :none
      assert Rooms.choices(context.workspace) == :none
    end

    test "offers a choice of the agents that answer in it, and only those", context do
      offered = [
        {"acme/one", [context.channel.name]},
        {"acme/two", [context.channel.name]},
        {"acme/quiet", []}
      ]

      :ok = WardrikTesting.Server.offer_agents(context.name, offered)

      assert {:choose, [%Offer{agent: "acme/one"}, %Offer{agent: "acme/two"}]} =
               Rooms.joined(context.workspace, "C1")

      assert {:ok, %Binding{agent: "acme/two"}, %Offer{}} =
               Rooms.chose(context.workspace, room: "C1", agent: "acme/two")

      assert Rooms.chose(context.workspace, room: "C1", agent: "acme/quiet") ==
               {:error, :not_offered}
    end

    test "unbinds a room the bot leaves", context do
      Rooms.joined(context.workspace, "C1")

      assert Rooms.left(context.workspace, "C1", @maria) == :ok
      assert Rooms.get(context.workspace, "C1") == nil
      assert WardrikChannel.received(context.workspace, mention("Hi", "1.1")) == :ignored
      assert Rooms.left(context.workspace, "C1") == :ok

      assert ["wardrik.room.bound", "wardrik.room.unbound"] =
               Enum.map(audited(context), & &1["type"])
    end

    test "has the agent answer every message, or only mentions", context do
      assert Rooms.answers(context.workspace, "C1", :everything) == {:error, :not_bound}
      Rooms.joined(context.workspace, "C1")

      assert {:ok, %Binding{answers: :everything}} =
               Rooms.answers(context.workspace, "C1", :everything)

      assert {:asked, _conversation} =
               WardrikChannel.received(context.workspace, %{
                 mention("Hi", "1.1")
                 | mentioned?: false
               })
    end
  end

  describe "threads" do
    setup context do
      Rooms.joined(context.workspace, "C1")
      :ok
    end

    test "answers a mention in a thread of its own, as whoever sent it, and replies after",
         context do
      conversation = conversation(context, "1.1")

      assert {:asked, ^conversation} =
               WardrikChannel.received(context.workspace, mention("Hi", "1.1"))

      assert_receive {:asked, ^conversation, "Hi", sender}
      assert sender == "#{context.channel.name}:T1/U3"

      assert_receive {:delivered,
                      %Outbound{thread: "1.1", body: {:reply, "Answered: Hi", ["1.1"]}}}

      assert {:asked, ^conversation} =
               WardrikChannel.received(context.workspace, reply("More", "1.1", "1.2"))

      assert_receive {:delivered,
                      %Outbound{thread: "1.1", body: {:reply, "Answered: More", ["1.2"]}}}
    end

    test "shows what the agent is doing while it works", context do
      WardrikChannel.received(context.workspace, mention("Hi", "1.1"))
      assert_receive {:delivered, %Outbound{body: {:status, "is thinking…"}}}
    end

    test "tries a post again that the chat app refused", context do
      :counters.put(context.refusals, 1, 1)
      WardrikChannel.received(context.workspace, mention("Hi", "1.1"))

      assert_receive {:refused, %Outbound{}}
      assert_receive {:delivered, %Outbound{body: {:reply, "Answered: Hi", ["1.1"]}}}, 3_000
    end

    test "says why a run failed", context do
      WardrikChannel.received(context.workspace, mention("fail now", "1.1"))
      assert_receive {:delivered, %Outbound{body: {:failed, "It broke."}}}
    end

    test "carries on from where it posted after the room's process stops", context do
      WardrikChannel.received(context.workspace, mention("Hi", "1.1"))
      assert_receive {:delivered, %Outbound{body: {:reply, "Answered: Hi", _answering}}}

      replies = Module.concat([context.name, "Channels", context.channel.name, "Replies"])
      :ok = DurableServer.Supervisor.terminate_child(replies, "T1/C1")
      WardrikChannel.received(context.workspace, reply("More", "1.1", "1.2"))

      assert_receive {:delivered, %Outbound{body: {:reply, "Answered: More", _answering}}}
      refute_received {:delivered, %Outbound{body: {:reply, "Answered: Hi", _answering}}}
    end

    test "reminds no room that isn't posting", context do
      assert WardrikChannel.Replies.remind(context.workspace,
               room: "C9",
               conversation: "acme/triage/x"
             ) == :ok
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
  end

  describe "deciding" do
    setup context do
      Rooms.joined(context.workspace, "C1")
      WardrikChannel.received(context.workspace, mention("echo hi", "1.1"))

      assert_receive {:delivered,
                      %Outbound{approvers: ["@maria"], body: {:waiting, [%Waiting{} = waiting]}}}

      %{waiting: waiting}
    end

    test "posts a waiting call with its arguments, and who asked", context do
      conversation = conversation(context, "1.1")

      assert %Waiting{
               conversation: ^conversation,
               interrupt: %Wardrik.Interrupt{id: "call_1", name: "echo"},
               arguments: %{"text" => "hi"},
               asked_by: asked_by
             } = context.waiting

      assert asked_by == "#{context.channel.name}:T1/U3"
    end

    test "lets an approver decide, and says who did", context do
      answer = %Answer{
        member: @maria,
        conversation: context.waiting.conversation,
        interrupt: "call_1",
        decision: {:approve, nil}
      }

      assert {:ok, %Wardrik.Decision{decision: :approved}} =
               WardrikChannel.decide(context.workspace, answer)

      assert_receive {:delivered, %Outbound{body: {:said, "Approved by maria."}}}
      assert_receive {:delivered, %Outbound{body: {:reply, "Done.", ["1.1"]}}}
    end

    test "lets whoever asked decide, and nobody else", context do
      %Waiting{conversation: conversation, asked_by: asked_by} = context.waiting

      answer = %Answer{
        member: @jon,
        conversation: conversation,
        interrupt: "call_1",
        asked_by: asked_by,
        decision: {:deny, nil}
      }

      assert WardrikChannel.decide(context.workspace, answer) ==
               {:error, context.channel.deciding}

      channel = context.channel.name

      assert_received {:authorizing,
                       %{
                         operation: "agent.deny",
                         scope: %{
                           principal: %{id: jon},
                           actor: {:channel, ^channel},
                           context: %{
                             asked_by: ^asked_by,
                             approver: false,
                             installation: %{owner: "acme", workspace: "T1"}
                           }
                         }
                       }}

      assert jon == "#{channel}:T1/#{@jon.id}"

      assert {:ok, %Wardrik.Decision{decision: :rejected}} =
               WardrikChannel.decide(context.workspace, %{
                 answer
                 | member: @ana,
                   decision: {:deny, "Not now."}
               })

      assert_receive {:delivered, %Outbound{body: {:said, "Denied by ana: Not now."}}}
    end

    test "says how the decision went, with what the decider said", context do
      answer = %Answer{
        member: @maria,
        conversation: context.waiting.conversation,
        interrupt: "call_1",
        decision: {:approve, "Once."}
      }

      assert {:ok, _decision} = WardrikChannel.decide(context.workspace, answer)

      assert_receive {:delivered, %Outbound{body: {:said, "Approved by maria: Once."}}}
    end

    test "says a run stopped before it answered", context do
      scope = Workspace.member_scope(context.workspace, @ana)
      :ok = Wardrik.Agent.cancel(scope, context.waiting.conversation)

      assert_receive {:delivered, %Outbound{body: {:stopped, ["1.1"]}}}
    end

    test "posts the waiting call again for a message behind it", context do
      assert {:asked, _conversation} =
               WardrikChannel.received(context.workspace, reply("Well?", "1.1", "1.2"))

      assert_receive {:delivered,
                      %Outbound{body: {:waiting, [%Waiting{interrupt: %{id: "call_1"}}]}}}
    end
  end

  test "names its approvers: the people named, anyone, or nobody", %{workspace: workspace} do
    assert Workspace.approver?(workspace, @maria)
    refute Workspace.approver?(workspace, @jon)
    assert Workspace.approver?(put_in(workspace.installation.approvers, :anyone), @jon)
    refute Workspace.approver?(put_in(workspace.installation.approvers, []), @maria)
  end

  describe "channels" do
    test "is named in lower-case letters, digits and -, and says where it's added" do
      passed = [server: S, wardrik: :w, events: :e, store: nil]

      assert_raise ArgumentError, ~r/lower-case/, fn ->
        WardrikChannel.channel(WardrikChannel.Test.Chat, [channel: "Chat", token: "t"] ++ passed)
      end

      assert_raise ArgumentError, ~r/token/, fn ->
        WardrikChannel.channel(WardrikChannel.Test.Chat, [channel: "chat"] ++ passed)
      end

      assert_raise NimbleOptions.ValidationError, ~r/:approvers/, fn ->
        WardrikChannel.channel(
          WardrikChannel.Test.Chat,
          [channel: "chat", token: "t", owner: "acme", approvers: "@maria"] ++ passed
        )
      end
    end

    test "is added with its token alone", %{channel: channel} do
      {module, config} = channel.installations
      {:ok, installation} = Channel.installation(channel, "T9")

      assert installation.owner == "acme"
      refute inspect(installation) =~ "xoxb"
      assert {:error, _why} = module.put(installation, config)

      assert module.delete(
               %Wardrik.Channel.Installations.Request{channel: channel.name, workspace: "T9"},
               config
             ) == :ok
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

      opts = channel_options(context)

      notification = %Wardrik.Channel.Notification{
        room: "#news",
        notice: notice,
        approvers: ["@maria"]
      }

      assert WardrikChannel.Test.Chat.notify(notification, opts) == :ok

      assert_receive {:delivered,
                      %Outbound{
                        room: "#news",
                        thread: nil,
                        body: {:notice, ^notice},
                        approvers: ["@maria"]
                      } =
                        outbound}

      assert outbound.installation.owner == "acme"

      assert {:skip, _why} =
               WardrikChannel.Test.Chat.notify(
                 %Wardrik.Channel.Notification{
                   room: "#news",
                   notice: %{notice | agent: "globex/digest"}
                 },
                 opts
               )
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

  describe "stored installations" do
    setup context do
      vault = :"vault #{context.channel.name}"

      start_supervised!(
        {WardrikVault, name: vault, store: context.store, keys: [WardrikVault.generate_key()]}
      )

      opts =
        context
        |> channel_options()
        |> Keyword.drop([:token, :owner])
        |> Keyword.merge(installations: :stored, vault: vault)

      %{stored: WardrikChannel.channel(WardrikChannel.Test.Chat, opts), vault: vault}
    end

    test "keep each workspace, its approvers kept and its token sealed in the vault", context do
      channel = context.stored

      installation = %Installation{
        channel: channel.name,
        workspace: "T1",
        owner: "acme",
        token: "xoxb-acme",
        approvers: ["@maria"]
      }

      assert Channel.installation(channel, "T1") == :error
      assert Channel.install(channel, installation) == :ok
      assert Channel.installation(channel, "T1") == {:ok, installation}

      assert WardrikVault.fetch(
               context.vault,
               %WardrikCore.Principal{id: "acme"},
               "#{channel.name}:T1"
             ) ==
               {:ok, "xoxb-acme"}

      assert Channel.uninstall(channel, "T1") == :ok
      assert Channel.installation(channel, "T1") == :error
      assert Channel.uninstall(channel, "T1") == :ok
    end

    test "find the workspace nearest an agent's owner: its user's, then its org's", context do
      channel = context.stored

      installed = fn workspace, owner ->
        installation = %Installation{
          channel: channel.name,
          workspace: workspace,
          owner: owner,
          token: "xoxb-#{workspace}",
          approvers: :anyone
        }

        :ok = Channel.install(channel, installation)
        installation
      end

      assert Channel.nearest(channel, "acme/triage") == :error

      org = installed.("T1", "acme")
      jon = installed.("T2", "acme/@jon")
      installed.("T3", "globex")

      assert Channel.nearest(channel, "acme/triage") == {:ok, org}
      assert Channel.nearest(channel, "acme/@jon/digest") == {:ok, jon}
      assert Channel.nearest(channel, "acme/@maria/digest") == {:ok, org}
    end

    test "seal nothing where the Wardrik keeps no vault", context do
      opts =
        context
        |> channel_options()
        |> Keyword.drop([:token, :owner])
        |> Keyword.put(:installations, :stored)

      channel = WardrikChannel.channel(WardrikChannel.Test.Chat, opts)

      installation = %Installation{
        channel: channel.name,
        workspace: "T1",
        owner: "acme",
        token: "x"
      }

      assert {:error, _why} = Channel.install(channel, installation)
      assert Channel.installation(channel, "T1") == :error
      assert Channel.uninstall(channel, "T1") == :ok
    end
  end

  test "acts as the channel: as the workspace for itself, as a member for them", %{
    workspace: workspace
  } do
    installation = %{owner: "acme", workspace: "T1"}
    name = workspace.channel.name
    id = "#{name}:T1"

    assert %Wardrik.Scope{
             principal: %{id: ^id},
             actor: {:channel, ^name},
             context: %{installation: ^installation}
           } = Workspace.scope(workspace)

    assert %Wardrik.Scope{actor: {:channel, ^name}, context: context} =
             Workspace.member_scope(workspace, @jon)

    assert context == %{installation: installation}

    answer = %Answer{
      member: @maria,
      conversation: "acme/triage/x",
      interrupt: "call_1",
      decision: {:approve, nil}
    }

    assert %Wardrik.Scope{context: %{approver: true, installation: ^installation} = deciding} =
             Workspace.deciding_scope(workspace, answer)

    refute Map.has_key?(deciding, :asked_by)
  end

  defp channel_options(context) do
    [
      server: WardrikTesting.Server,
      wardrik: context.name,
      events: context.events,
      channel: context.channel.name,
      store: context.store,
      token: "xoxb-test",
      owner: "acme",
      approvers: ["@maria"],
      test: self(),
      refusals: context.refusals
    ]
  end
end
