defmodule Wardrik.ChatTest do
  use ExUnit.Case, async: true

  import Wardrik.Chat.Test

  alias Wardrik.Channel.Installation
  alias Wardrik.Channel.Notification
  alias Wardrik.Chat.Answer
  alias Wardrik.Chat.Binding
  alias Wardrik.Chat.Channel
  alias Wardrik.Chat.Inbound
  alias Wardrik.Chat.Member
  alias Wardrik.Chat.Offer
  alias Wardrik.Chat.Outbound
  alias Wardrik.Chat.Rating
  alias Wardrik.Chat.Rooms
  alias Wardrik.Chat.Step
  alias Wardrik.Chat.Test.Chat
  alias Wardrik.Chat.Waiting
  alias Wardrik.Chat.Workspace

  setup :start_channel

  @maria %Member{id: "U1", name: "maria"}
  @jon %Member{id: "U2", name: "jon"}
  @ana %Member{id: "U3", name: "ana"}

  defp mention(text, id, sender \\ @ana),
    do: %Inbound{room: "C1", id: id, sender: sender, text: text, mentioned?: true}

  defp reply(text, thread, id, sender \\ @ana),
    do: %Inbound{room: "C1", thread: thread, id: id, sender: sender, text: text}

  defp audit(context) do
    %{events: events} = Wardrik.EventLog.audit(context.events)
    for %{"type" => "wardrik.room." <> _rest} = event <- events, do: event
  end

  defp conversation(context, thread),
    do: {"agt_triage", "#{context.channel.name}.T1.C1.#{thread}"}

  describe "rooms" do
    test "binds a room to the one agent offered, and records who did", context do
      assert {:bound, %Binding{agent: "agt_triage", answers: :mentions},
              %Offer{agent: "agt_triage", description: "Answers agt_triage."}} =
               Rooms.join(context.workspace, "C1", @maria)

      assert %Binding{agent: "agt_triage"} = Rooms.get(context.workspace, "C1")

      assert [%{"type" => "wardrik.room.bound", "data" => data}] = audit(context)
      assert %{"room" => "C1", "agent" => %{"id" => "agt_triage"}, "actor" => actor} = data
      assert actor["id"] == "maria"
    end

    @tag offered: []
    test "offers nothing where no agent answers in it", context do
      assert Rooms.join(context.workspace, "C1") == :none
      assert Rooms.choices(context.workspace) == :none
    end

    test "offers a choice of the agents that answer in it, and only those", context do
      offered = [
        {"agt_one", [context.channel.name]},
        {"agt_two", [context.channel.name]},
        {"agt_quiet", []}
      ]

      :ok = Wardrik.Testing.Server.offer_agents(context.name, offered)

      assert {:choose, [%Offer{agent: "agt_one"}, %Offer{agent: "agt_two"}]} =
               Rooms.join(context.workspace, "C1")

      assert {:ok, %Binding{agent: "agt_two"}, %Offer{}} =
               Rooms.chose(context.workspace, room: "C1", agent: "agt_two")

      assert Rooms.chose(context.workspace, room: "C1", agent: "agt_quiet") ==
               {:error, :not_offered}
    end

    test "unbinds a room the bot leaves", context do
      Rooms.join(context.workspace, "C1")

      assert Rooms.leave(context.workspace, "C1", @maria) == :ok
      assert Rooms.get(context.workspace, "C1") == nil
      assert Wardrik.Chat.answer_inbound(context.workspace, mention("Hi", "1.1")) == :ignored
      assert Rooms.leave(context.workspace, "C1") == :ok

      types =
        context
        |> audit()
        |> Enum.map(& &1["type"])

      assert ["wardrik.room.bound", "wardrik.room.unbound"] = types
    end

    test "has the agent answer every message, or only mentions", context do
      assert Rooms.answers(context.workspace, "C1", :everything) == {:error, :not_bound}
      Rooms.join(context.workspace, "C1")

      assert {:ok, %Binding{answers: :everything}} =
               Rooms.answers(context.workspace, "C1", :everything)

      assert {:asked, _conversation} =
               Wardrik.Chat.answer_inbound(context.workspace, %{
                 mention("Hi", "1.1")
                 | mentioned?: false
               })
    end
  end

  describe "threads" do
    setup context do
      Rooms.join(context.workspace, "C1")
      :ok
    end

    test "answers a mention in a thread of its own, as whoever sent it, and replies after",
         context do
      conversation = conversation(context, "1.1")

      assert {:asked, ^conversation} =
               Wardrik.Chat.answer_inbound(context.workspace, mention("Hi", "1.1"))

      assert_receive {:asked, ^conversation, "Hi", sender}
      assert sender == "ana"

      assert_receive {:delivered,
                      %Outbound{thread: "1.1", body: {:reply, "Answered: Hi", ["1.1"]}}}

      assert {:asked, ^conversation} =
               Wardrik.Chat.answer_inbound(context.workspace, reply("More", "1.1", "1.2"))

      assert_receive {:delivered,
                      %Outbound{thread: "1.1", body: {:reply, "Answered: More", ["1.2"]}}}
    end

    test "follows each thread's own conversation, and no other log", context do
      {agent, conversation} = conversation(context, "1.1")
      Wardrik.Chat.answer_inbound(context.workspace, mention("Hi", "1.1"))
      assert_receive {:delivered, %Outbound{body: {:reply, "Answered: Hi", _answering}}}

      look_alikes = [
        {"agt_other", conversation},
        {agent, nil},
        {agent, conversation <> "0"},
        {agent, "#{context.channel.name}.T1.C2.1.1"}
      ]

      for log <- look_alikes do
        said = %{"role" => "assistant", "parts" => [%{"type" => "text", "content" => "Not here"}]}
        data = %{"run" => %{"id" => "r9"}, "messages" => [said]}
        :ok = Wardrik.EventLog.append(context.events, log, {"run.completed", "runs/r9", data})
      end

      Wardrik.Chat.answer_inbound(context.workspace, reply("More", "1.1", "1.2"))
      assert_receive {:delivered, %Outbound{body: {:reply, "Answered: More", ["1.2"]}}}
      refute_received {:delivered, %Outbound{body: {:reply, "Not here", _answering}}}
    end

    test "follows a new thread from its end, and keeps following the others", context do
      Wardrik.Chat.answer_inbound(context.workspace, mention("Hi", "1.1"))
      assert_receive {:delivered, %Outbound{thread: "1.1", body: {:reply, "Answered: Hi", _}}}

      Wardrik.Chat.answer_inbound(context.workspace, mention("Hey", "2.1"))
      assert_receive {:delivered, %Outbound{thread: "2.1", body: {:reply, "Answered: Hey", _}}}

      Wardrik.Chat.answer_inbound(context.workspace, reply("More", "1.1", "1.2"))
      assert_receive {:delivered, %Outbound{thread: "1.1", body: {:reply, "Answered: More", _}}}
      refute_received {:delivered, %Outbound{body: {:reply, "Answered: Hi", _answering}}}
    end

    test "posts nothing a replaced follower hands it", context do
      Wardrik.Chat.answer_inbound(context.workspace, mention("Hi", "1.1"))
      assert_receive {:delivered, %Outbound{body: {:reply, "Answered: Hi", _answering}}}

      replies = Module.concat([context.name, "Channels", context.channel.name, "Replies"])
      {pid, _meta} = DurableServer.Supervisor.lookup(replies, "T1/C1")
      event = %Wardrik.Event{type: "wardrik.run.failed", data: %{"error" => %{"message" => "x"}}}

      assert GenServer.call(pid, {:event, event, "c"}) == :ok
      refute_receive {:delivered, %Outbound{body: {:failed, "x"}}}, 50
    end

    test "shows each step of a run, for whoever asked, then ends with the reply", context do
      Wardrik.Chat.answer_inbound(context.workspace, mention("Hi", "1.1"))

      assert_receive {:delivered,
                      %Outbound{
                        body: {:progress, [%Step{title: "Thinking", status: :running}]},
                        progress: nil,
                        asker: "U3"
                      }}

      assert_receive {:delivered,
                      %Outbound{
                        body: {:progress, [%Step{title: "Thinking", status: :done}]},
                        progress: "progress-1.1"
                      }}

      assert_receive {:delivered,
                      %Outbound{body: {:reply, "Answered: Hi", ["1.1"]}, progress: "progress-1.1"}}
    end

    test "shows a step's progress again while it runs quietly", context do
      Wardrik.Chat.answer_inbound(context.workspace, mention("Hi", "1.1"))
      assert_receive {:delivered, %Outbound{body: {:reply, "Answered: Hi", _answering}}}

      log = conversation(context, "1.1")
      run = %{"run" => %{"id" => "r2", "message_ids" => []}}
      :ok = Wardrik.EventLog.append(context.events, log, {"run.started", "runs/r2", run})

      started = %{
        "message" => %{"id" => "msg_2"},
        "request" => %{"model" => "test"},
        "decided" => %{"by" => "default"}
      }

      :ok =
        Wardrik.EventLog.append(
          context.events,
          log,
          {"message.started", "messages/msg_2", started}
        )

      assert_receive {:delivered, %Outbound{body: {:progress, [%Step{id: "msg_2"}]}}}

      replies = Module.concat([context.name, "Channels", context.channel.name, "Replies"])
      {pid, _meta} = DurableServer.Supervisor.lookup(replies, "T1/C1")
      send(pid, {:beat, log})

      assert_receive {:delivered,
                      %Outbound{
                        body: {:progress, [%Step{id: "msg_2", status: :running}]},
                        progress: "progress-1.1"
                      }}
    end

    test "starts a new progress for each run", context do
      Wardrik.Chat.answer_inbound(context.workspace, mention("Hi", "1.1"))
      assert_receive {:delivered, %Outbound{body: {:reply, "Answered: Hi", _answering}}}

      Wardrik.Chat.answer_inbound(context.workspace, reply("More", "1.1", "1.2"))
      assert_receive {:delivered, %Outbound{body: {:progress, _steps}, progress: nil}}
    end

    test "shows a call the agent runs as waiting, then the calls it waits on", context do
      Wardrik.Chat.answer_inbound(context.workspace, mention("echo", "1.1"))

      assert_receive {:delivered,
                      %Outbound{
                        body: {:progress, [%Step{title: "Running echo", status: :running}]}
                      }}

      assert_receive {:delivered,
                      %Outbound{
                        body: {:progress, [%Step{title: "Running echo", status: :waiting}]}
                      }}

      assert_receive {:delivered, %Outbound{body: {:waiting, _calls}, progress: "progress-1.1"}}
    end

    test "tries a post again that the chat app refused", context do
      :counters.put(context.refusals, 1, 1)
      Wardrik.Chat.answer_inbound(context.workspace, mention("Hi", "1.1"))

      assert_receive {:refused, %Outbound{}}
      assert_receive {:delivered, %Outbound{body: {:reply, "Answered: Hi", ["1.1"]}}}, 3_000
    end

    test "moves on from a post the adapter declines", context do
      Wardrik.Chat.answer_inbound(context.workspace, mention("skip", "1.1"))
      assert_receive {:skipped, %Outbound{}}

      Wardrik.Chat.answer_inbound(context.workspace, reply("Hi", "1.1", "1.2"))
      assert_receive {:delivered, %Outbound{body: {:reply, "Answered: Hi", _answering}}}
      refute_received {:skipped, _outbound}
    end

    test "says why a run failed", context do
      Wardrik.Chat.answer_inbound(context.workspace, mention("fail now", "1.1"))
      assert_receive {:delivered, %Outbound{body: {:failed, "It broke."}}}
    end

    test "carries on from where it posted after the room's process stops", context do
      Wardrik.Chat.answer_inbound(context.workspace, mention("Hi", "1.1"))
      assert_receive {:delivered, %Outbound{body: {:reply, "Answered: Hi", _answering}}}

      replies = Module.concat([context.name, "Channels", context.channel.name, "Replies"])
      :ok = DurableServer.Supervisor.terminate_child(replies, "T1/C1")
      Wardrik.Chat.answer_inbound(context.workspace, reply("More", "1.1", "1.2"))

      assert_receive {:delivered, %Outbound{body: {:reply, "Answered: More", _answering}}}
      refute_received {:delivered, %Outbound{body: {:reply, "Answered: Hi", _answering}}}
    end

    test "reminds no room that isn't posting", context do
      assert Wardrik.Chat.Replies.remind(context.workspace,
               room: "C9",
               agent: "agt_triage",
               conversation: "chat.T1.C9.x"
             ) == :ok
    end

    test "leaves alone what isn't for it", context do
      assert Wardrik.Chat.answer_inbound(context.workspace, %{
               mention("Hi", "1.1")
               | mentioned?: false
             }) ==
               :ignored

      assert Wardrik.Chat.answer_inbound(context.workspace, reply("Hi", "9.9", "9.10")) ==
               :ignored

      assert Wardrik.Chat.answer_inbound(context.workspace, %{mention("Hi", "1.1") | room: "C2"}) ==
               :ignored
    end
  end

  describe "deciding" do
    setup context do
      Rooms.join(context.workspace, "C1")
      Wardrik.Chat.answer_inbound(context.workspace, mention("echo hi", "1.1"))

      assert_receive {:delivered, %Outbound{body: {:waiting, [%Waiting{} = waiting]}}}

      %{waiting: waiting}
    end

    test "posts a waiting call with its arguments, and who asked", context do
      {agent, conversation} = conversation(context, "1.1")

      assert %Waiting{
               agent: ^agent,
               conversation: ^conversation,
               interrupt: %Wardrik.Interrupt{id: "call_1", name: "echo"},
               arguments: %{"text" => "hi"},
               asked_by: asked_by
             } = context.waiting

      assert asked_by == "ana"
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
               Wardrik.Chat.decide(context.workspace, answer)

      assert_receive {:delivered, %Outbound{body: {:said, "Approved by maria."}}}
      assert_receive {:delivered, %Outbound{body: {:reply, "Done.", ["1.1"]}}}
    end

    test "carries the next steps the run suggested with its reply", context do
      log = {context.waiting.agent, context.waiting.conversation}
      suggested = {"prompts.suggested", "agents/x", %{"prompts" => ["Send it"]}}
      :ok = Wardrik.EventLog.append(context.events, log, suggested)

      answer = %Answer{
        member: @maria,
        agent: context.waiting.agent,
        conversation: context.waiting.conversation,
        interrupt: "call_1",
        decision: {:approve, nil}
      }

      assert {:ok, _decision} = Wardrik.Chat.decide(context.workspace, answer)

      assert_receive {:delivered,
                      %Outbound{body: {:reply, "Done.", ["1.1"]}, prompts: ["Send it"]}}
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

      assert Wardrik.Chat.decide(context.workspace, answer) ==
               {:error, context.channel.deciding}

      channel = context.channel.name

      assert_received {:authorizing,
                       %{
                         operation: "agent.deny",
                         scope: %{
                           principal: %{id: jon},
                           actor: {:channel, ^channel},
                           context: seen
                         }
                       }}

      assert jon == "jon"
      assert seen == %{asked_by: asked_by, installation: %{owner: "acme", workspace: "T1"}}

      assert {:ok, %Wardrik.Decision{decision: :rejected}} =
               Wardrik.Chat.decide(context.workspace, %{
                 answer
                 | member: @ana,
                   decision: {:deny, "Not now."}
               })

      assert_receive {:delivered, %Outbound{body: {:said, "Denied by ana: Not now."}}}
    end

    test "says how the decision went, with what the decider said", context do
      answer = %Answer{
        member: @maria,
        agent: context.waiting.agent,
        conversation: context.waiting.conversation,
        interrupt: "call_1",
        decision: {:approve, "Once."}
      }

      assert {:ok, _decision} = Wardrik.Chat.decide(context.workspace, answer)

      assert_receive {:delivered, %Outbound{body: {:said, "Approved by maria: Once."}}}
    end

    test "says a run stopped before it answered", context do
      {:ok, scope} = Workspace.member_scope(context.workspace, @ana)
      %Waiting{agent: agent, conversation: conversation} = context.waiting
      :ok = Wardrik.Agent.cancel(scope, agent, conversation: conversation)

      assert_receive {:delivered, %Outbound{body: {:stopped, ["1.1"]}}}
    end

    test "posts the waiting call again for a message behind it", context do
      assert {:asked, _conversation} =
               Wardrik.Chat.answer_inbound(context.workspace, reply("Well?", "1.1", "1.2"))

      assert_receive {:delivered,
                      %Outbound{body: {:waiting, [%Waiting{interrupt: %{id: "call_1"}}]}}}
    end
  end

  defmodule ByEmail do
    @behaviour Wardrik.Chat.Identities

    @impl Wardrik.Chat.Identities
    def identify(request, _opts), do: {:ok, %Wardrik.Principal{id: request.email}}
  end

  describe "stopping" do
    setup context do
      Rooms.join(context.workspace, "C1")
      :ok
    end

    test "cancels the thread's run, as the member, with who asked for it", context do
      Wardrik.Chat.answer_inbound(context.workspace, mention("echo", "1.1"))
      assert_receive {:delivered, %Outbound{body: {:waiting, _calls}}}

      assert Wardrik.Chat.stop(context.workspace, @ana, room: "C1", thread: "1.1") == :ok
      assert_receive {:delivered, %Outbound{body: {:stopped, ["1.1"]}}}
    end

    test "says when nothing is running in the thread", context do
      Wardrik.Chat.answer_inbound(context.workspace, mention("Hi", "1.1"))
      assert_receive {:delivered, %Outbound{body: {:reply, "Answered: Hi", _answering}}}

      assert Wardrik.Chat.stop(context.workspace, @ana, room: "C1", thread: "1.1") ==
               :not_running

      assert Wardrik.Chat.stop(context.workspace, @ana, room: "C9", thread: "1.1") ==
               :not_running
    end
  end

  describe "prompts" do
    defmodule Suggests do
      @behaviour Wardrik.Chat.Prompts

      @impl true
      def suggest(request, test: test) do
        send(test, {:suggesting, request})
        ["Plan my week"]
      end
    end

    test "are Wardrik's own unless the channel names others", context do
      assert Wardrik.Chat.suggest_prompts(context.workspace, @ana) ==
               Wardrik.Chat.Prompts.defaults()
    end

    test "are asked of the channel's prompts for the member starting a conversation", context do
      channel = %{context.channel | prompts: {Suggests, test: self()}}
      workspace = %{context.workspace | channel: channel}

      assert Wardrik.Chat.suggest_prompts(workspace, @ana) == ["Plan my week"]

      assert_received {:suggesting,
                       %Wardrik.Chat.Prompts.Request{workspace: "T1", member: "U3", channel: name}}

      assert name == channel.name
    end
  end

  describe "ratings" do
    setup context do
      Rooms.join(context.workspace, "C1")
      :ok
    end

    defp rating(context, member, rating),
      do: %Rating{
        member: member,
        agent: "agt_triage",
        conversation: "#{context.channel.name}.T1.C1.1.1",
        run: "r1",
        rating: rating
      }

    test "name the run a reply answers", context do
      Wardrik.Chat.answer_inbound(context.workspace, mention("Hi", "1.1"))
      conversation = "#{context.channel.name}.T1.C1.1.1"

      assert_receive {:delivered,
                      %Outbound{
                        body: {:reply, "Answered: Hi", _},
                        agent: "agt_triage",
                        conversation: ^conversation,
                        run: "r1"
                      }}
    end

    test "are kept in the conversation's log, with who rated", context do
      assert Wardrik.Chat.rate(context.workspace, rating(context, @maria, :negative)) == :ok

      {:ok, %{events: events}} =
        Wardrik.EventLog.page(context.events, [conversation(context, "1.1")])

      assert [
               %{
                 "type" => "wardrik.run.rated",
                 "subject" => "runs/r1",
                 "data" => %{
                   "run" => %{"id" => "r1"},
                   "rating" => "negative",
                   "rated_by" => %{"id" => "maria"}
                 }
               }
             ] = events
    end

    test "are refused from a member your app doesn't know", context do
      stranger = %Member{id: "U9", name: "stranger"}

      assert Wardrik.Chat.rate(context.workspace, rating(context, stranger, :positive)) ==
               {:error, "Nobody here knows you yet."}
    end
  end

  describe "direct messages" do
    defp build_direct_message(text, id, opts \\ []) do
      %Inbound{
        room: "D1",
        thread: opts[:thread],
        id: id,
        sender: Keyword.get(opts, :sender, @ana),
        text: text,
        direct?: true,
        parent: opts[:parent],
        parent_notice: opts[:parent_notice]
      }
    end

    @tag direct: %{"ana" => "agt_triage", "jon" => "agt_elsewhere"}
    test "are answered by the sender's agent, every message, each in a thread of its own",
         context do
      conversation = {"agt_triage", "#{context.channel.name}.T1.D1.2.1"}

      assert {:asked, ^conversation} =
               Wardrik.Chat.answer_inbound(context.workspace, build_direct_message("Hi", "2.1"))

      assert_receive {:asked, ^conversation, "Hi", "ana"}

      assert_receive {:delivered,
                      %Outbound{room: "D1", thread: "2.1", body: {:reply, "Answered: Hi", _ids}}}

      assert {:asked, ^conversation} =
               Wardrik.Chat.answer_inbound(
                 context.workspace,
                 build_direct_message("More", "2.2", thread: "2.1")
               )

      assert {:asked, {"agt_triage", other}} =
               Wardrik.Chat.answer_inbound(
                 context.workspace,
                 build_direct_message("Again", "2.3")
               )

      assert other != elem(conversation, 1)
      assert Rooms.get(context.workspace, "D1") == nil
    end

    @tag direct: %{"ana" => "agt_triage"}
    test "are asked with the message they reply to quoted", context do
      inbound = build_direct_message("Why?", "5.2", thread: "5.1", parent: "It failed.\nTwice.")

      assert {:asked, _conversation} = Wardrik.Chat.answer_inbound(context.workspace, inbound)

      assert_receive {:asked, _conversation,
                      "This replies in the thread of this message:\n> It failed.\n> Twice.\n\nWhy?",
                      "ana"}
    end

    @tag direct: %{"ana" => "agt_triage"}
    test "are told which agent and conversation a notice they reply to is about", context do
      notice = %{"agent" => "agt_digest", "name" => "digest", "conversation" => "daily"}

      inbound =
        build_direct_message("Why?", "6.2",
          thread: "6.1",
          parent: "digest stopped.",
          parent_notice: notice
        )

      assert {:asked, _conversation} = Wardrik.Chat.answer_inbound(context.workspace, inbound)

      assert_receive {:asked, _conversation,
                      "This replies in the thread of this message:\n> digest stopped.\n" <>
                        "It's a notice about digest (agt_digest), from its conversation daily." <>
                        "\n\nWhy?", "ana"}
    end

    @tag direct: %{"ana" => "agt_triage", "jon" => "agt_elsewhere"}
    test "tell whoever they can't answer why", context do
      answer =
        &Wardrik.Chat.answer_inbound(
          context.workspace,
          build_direct_message("Hi", "3.1", sender: &1)
        )

      assert answer.(@maria) == {:error, "You have no assistant yet."}

      assert answer.(@jon) ==
               {:error,
                "The agent that answers direct messages isn't offered in #{context.channel.name}."}

      assert answer.(%Member{id: "U9", name: "stranger"}) ==
               {:error, "Nobody here knows you yet."}

      refute_received {:asked, _conversation, _text, _sender}
    end

    test "aren't answered where the channel names no agent for them", context do
      assert Wardrik.Chat.answer_inbound(context.workspace, build_direct_message("Hi", "4.1")) ==
               {:error, "No agent answers direct messages here."}
    end
  end

  test "your app's identities see the member's email address", context do
    channel = %{context.workspace.channel | identities: {ByEmail, []}}
    member = %Member{id: "U9", name: "maria", email: "maria@acme.com"}

    assert {:ok, %Wardrik.Principal{id: "maria@acme.com"}} =
             Wardrik.Chat.Channel.identify(channel, "T1", member)
  end

  describe "members your app doesn't know" do
    setup context do
      Rooms.join(context.workspace, "C1")
      :ok
    end

    test "can't ask, and are told why", context do
      stranger = %Member{id: "U9", name: "stranger"}

      assert Wardrik.Chat.answer_inbound(context.workspace, mention("Hi", "1.1", stranger)) ==
               {:error, "Nobody here knows you yet."}

      refute_received {:asked, _conversation, _text, _sender}
      assert Workspace.list_offered_agents(context.workspace, stranger) == []
    end

    test "can't decide, and are told why", context do
      Wardrik.Chat.answer_inbound(context.workspace, mention("echo hi", "1.1"))
      assert_receive {:delivered, %Outbound{body: {:waiting, [%Waiting{} = waiting]}}}

      answer = %Answer{
        member: %Member{id: "U9", name: "stranger"},
        agent: waiting.agent,
        conversation: waiting.conversation,
        interrupt: "call_1",
        asked_by: waiting.asked_by,
        decision: {:approve, nil}
      }

      assert Wardrik.Chat.decide(context.workspace, answer) ==
               {:error, "Nobody here knows you yet."}

      refute_received {:authorizing, _request}
    end
  end

  describe "channels" do
    test "is named in lower-case letters, digits and -, and says where it's added" do
      passed = [server: S, wardrik: :w, events: :e, store: nil]

      identified = [identities: {Wardrik.Chat.Test.Members, members: %{}}] ++ passed

      assert_raise ArgumentError, ~r/lower-case/, fn ->
        Wardrik.Chat.channel(
          Wardrik.Chat.Test.Chat,
          [channel: "Chat", token: "t"] ++ identified
        )
      end

      assert_raise ArgumentError, ~r/token/, fn ->
        Wardrik.Chat.channel(Wardrik.Chat.Test.Chat, [channel: "chat"] ++ identified)
      end

      identities = {Wardrik.Chat.Test.Members, members: %{}}

      assert_raise NimbleOptions.ValidationError, ~r/:identities/, fn ->
        Wardrik.Chat.channel(
          Wardrik.Chat.Test.Chat,
          [channel: "chat", token: "t", owner: "acme"] ++ passed
        )
      end

      channel =
        Wardrik.Chat.channel(
          Wardrik.Chat.Test.Chat,
          [channel: "chat", token: "t", owner: "acme", identities: identities] ++
            Keyword.put(passed, :store, Wardrik.Store.ETS.new(name: :unused))
        )

      refute Map.has_key?(channel, :approvers)
      refute Keyword.has_key?(Wardrik.Chat.Channel.schema().schema, :approvers)

      refute Map.has_key?(
               %Installation{channel: "c", workspace: "w", owner: "o", token: "t"},
               :approvers
             )
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
    test "knows a conversation in one of the workspace's threads", context do
      {:ok, workspace} =
        Chat
        |> Wardrik.Chat.channel(channel_options(context))
        |> Wardrik.Chat.workspace("T1")

      thread = Workspace.conversation(workspace, room: "C1", thread: "1696.1234")
      assert Workspace.thread?(workspace, thread)
      refute Workspace.thread?(workspace, "api-1")
      refute Workspace.thread?(workspace, nil)
    end

    test "finds the room and thread a conversation belongs to", context do
      {:ok, workspace} =
        Chat
        |> Wardrik.Chat.channel(channel_options(context))
        |> Wardrik.Chat.workspace("T1")

      thread = Workspace.conversation(workspace, room: "C1", thread: "1696.1234")
      assert {:ok, where} = Workspace.locate(workspace, thread)
      assert where == [room: "C1", thread: "1696.1234"]
      assert Workspace.conversation(workspace, where) == thread

      assert Workspace.locate(workspace, "api-1") == :error
      assert Workspace.locate(workspace, nil) == :error
    end

    test "posts a notice in the room itself, in the workspace it names", context do
      notice = %Wardrik.Notice{
        agent: "agt_digest",
        kind: :finished,
        at: DateTime.utc_now(),
        text: "Done."
      }

      opts = channel_options(context)

      notification = %Notification{workspace: "T1", room: "#news", notice: notice}

      assert Chat.notify(notification, opts) == :ok

      assert_receive {:delivered,
                      %Outbound{room: "#news", thread: nil, body: {:notice, ^notice}} = outbound}

      assert outbound.installation.workspace == "T1"
    end

    test "reads a parked turn's calls from its notice" do
      interrupt = %Wardrik.Interrupt{id: "call_1", name: "echo"}

      notice = %Wardrik.Notice{
        agent: "agt_triage",
        kind: :parked,
        at: DateTime.utc_now(),
        calls: [%{interrupt: interrupt, arguments: %{"text" => "hi"}}]
      }

      assert Waiting.from_notice(notice) == [
               %Waiting{
                 agent: "agt_triage",
                 conversation: nil,
                 interrupt: interrupt,
                 arguments: %{"text" => "hi"}
               }
             ]

      assert [%Waiting{agent: "agt_triage", conversation: "C1"}] =
               Waiting.from_notice(%{notice | conversation: "C1"})
    end
  end

  describe "stored installations" do
    setup context do
      vault = :"vault #{context.channel.name}"

      start_supervised!(
        {Wardrik.Vault, name: vault, store: context.store, keys: [Wardrik.Vault.generate_key()]}
      )

      opts =
        context
        |> channel_options()
        |> Keyword.drop([:token, :owner])
        |> Keyword.merge(installations: :stored, vault: vault)

      %{stored: Wardrik.Chat.channel(Wardrik.Chat.Test.Chat, opts), vault: vault}
    end

    test "keep each workspace, its owner kept and its token sealed in the vault", context do
      channel = context.stored

      installation = %Installation{
        channel: channel.name,
        workspace: "T1",
        owner: "acme",
        token: "xoxb-acme"
      }

      assert Channel.installation(channel, "T1") == :error
      assert Channel.install(channel, installation) == :ok
      assert Channel.installation(channel, "T1") == {:ok, installation}

      assert Wardrik.Vault.fetch(
               context.vault,
               %Wardrik.Principal{id: "acme"},
               "#{channel.name}:T1"
             ) ==
               {:ok, "xoxb-acme"}

      assert Channel.uninstall(channel, "T1") == :ok
      assert Channel.installation(channel, "T1") == :error
      assert Channel.uninstall(channel, "T1") == :ok
    end

    test "find the workspaces an owner holds, exactly", context do
      channel = context.stored

      installed = fn workspace, owner ->
        installation = %Installation{
          channel: channel.name,
          workspace: workspace,
          owner: owner,
          token: "xoxb-#{workspace}"
        }

        :ok = Channel.install(channel, installation)
        installation
      end

      assert Channel.list_installations(channel, "acme") == []

      acme = installed.("T1", "acme")
      installed.("T2", "acme-jon")

      assert Channel.list_installations(channel, "acme") == [acme]
      assert Channel.list_installations(channel, "acme-maria") == []
    end

    test "post a notice only in the workspace it names, and skip one not added", context do
      channel = context.stored

      opts =
        context
        |> channel_options()
        |> Keyword.drop([:token, :owner])
        |> Keyword.merge(installations: :stored, vault: context.vault)

      for {workspace, owner} <- [{"T1", "acme"}, {"T3", "globex"}] do
        installation = %Installation{
          channel: channel.name,
          workspace: workspace,
          owner: owner,
          token: "xoxb-#{workspace}"
        }

        :ok = Channel.install(channel, installation)
      end

      notice = %Wardrik.Notice{agent: "agt_digest", kind: :finished, at: DateTime.utc_now()}
      notification = %Notification{workspace: "T1", room: "#news", notice: notice}

      assert Chat.notify(notification, opts) == :ok
      assert_receive {:delivered, %Outbound{installation: %{workspace: "T1", owner: "acme"}}}

      assert {:skip, why} =
               Chat.notify(%{notification | workspace: "T9"}, opts)

      assert why =~ "T9"
      refute_received {:delivered, _outbound}
    end

    test "seal nothing where the Wardrik keeps no vault", context do
      opts =
        context
        |> channel_options()
        |> Keyword.drop([:token, :owner])
        |> Keyword.put(:installations, :stored)

      channel = Wardrik.Chat.channel(Wardrik.Chat.Test.Chat, opts)

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

  test "acts as the channel: for the installation's owner itself, as a member's user for them",
       %{workspace: workspace} do
    installation = %{owner: "acme", workspace: "T1"}
    name = workspace.channel.name

    assert %Wardrik.Scope{
             principal: %{id: "acme"},
             actor: {:channel, ^name},
             context: %{installation: ^installation}
           } = Workspace.scope(workspace)

    assert {:ok, %Wardrik.Scope{principal: %{id: "jon"}, actor: {:channel, ^name}} = scope} =
             Workspace.member_scope(workspace, @jon)

    assert scope.context == %{installation: installation}

    answer = %Answer{
      member: @maria,
      agent: "agt_triage",
      conversation: "chat.T1.C9.x",
      interrupt: "call_1",
      decision: {:approve, nil}
    }

    assert {:ok, %Wardrik.Scope{principal: %{id: "maria"}, context: deciding}} =
             Workspace.deciding_scope(workspace, answer)

    assert deciding == %{installation: installation}

    assert {:ok, %Wardrik.Scope{context: %{asked_by: "jon"}}} =
             Workspace.deciding_scope(workspace, %{answer | asked_by: "jon"})
  end

  defp channel_options(context) do
    [
      server: Wardrik.Testing.Server,
      wardrik: context.name,
      events: context.events,
      channel: context.channel.name,
      store: context.store,
      token: "xoxb-test",
      owner: "acme",
      identities: {Wardrik.Chat.Test.Members, members: members()},
      test: self(),
      refusals: context.refusals
    ]
  end
end
