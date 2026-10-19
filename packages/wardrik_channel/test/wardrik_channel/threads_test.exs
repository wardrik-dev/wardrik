defmodule WardrikChannel.ThreadsTest do
  use ExUnit.Case, async: true

  alias Wardrik.AgentID
  alias Wardrik.Conversation.Assistant
  alias Wardrik.Event.ToolStarted
  alias Wardrik.Fleet
  alias Wardrik.LLM.Turn
  alias Wardrik.Principal
  alias Wardrik.Resource
  alias Wardrik.Test.AgentRunners
  alias Wardrik.Test.Script
  alias WardrikChannel.Approvers
  alias WardrikChannel.Binding
  alias WardrikChannel.Context
  alias WardrikChannel.Inbound
  alias WardrikChannel.Installations
  alias WardrikChannel.Offer
  alias WardrikChannel.Outbound
  alias WardrikChannel.Replies
  alias WardrikChannel.Room
  alias WardrikChannel.Rooms
  alias WardrikChannel.Workspace
  alias WardrikNotify.Notice

  @maria Principal.new(:channel, "slack/T1/U1", name: "maria")

  @doc false
  def offering(agent, _channel), do: [%Offer{agent: agent}]

  @doc false
  def starting(options, _channel, agent), do: Fleet.spawn(agent, options)

  @doc false
  def approving(approvers, _channel), do: %Approvers.Named{names: approvers}

  @doc false
  def working(test, %Turn{} = turn) do
    send(test, {:working, self()})
    work(turn)
  end

  # Starts each call it is told to, until it is released or interrupted.
  defp work(turn) do
    receive do
      {:call, name} ->
        Wardrik.Event.emit(turn.run.source, %ToolStarted{
          call_id: name,
          name: name,
          arguments: %{},
          idempotency_key: name,
          decided_by: %{by: :default, hooks: []}
        })

        work(turn)

      :release ->
        Turn.done(turn, [Assistant.new("Done.")])

      :interrupt ->
        Turn.done(turn, [])
    end
  end

  # A channel of its own, delivering to the test, posted in by a
  # WardrikChannel.Replies of its own started with it, with a room bound to
  # an agent whose threads run on `runner`, and resume on `:resume`.
  defp bound(runner, opts \\ []) do
    agent = Wardrik.Test.Fleet.id("books")
    name = "chat-#{System.unique_integer([:positive])}"
    replies = :"replies-#{name}"

    channels =
      WardrikChannel.channels(
        [
          {name,
           {WardrikChannel.Test.Adapter,
            test: self(), refusals: opts[:refusals], unshown: opts[:unshown]}}
        ],
        host:
          Wardrik.Host.new(
            store: Wardrik.Test.store(),
            issuer: %WardrikChannel.Test.Issuer{reach: [Principal.id(@maria)]}
          ),
        installations: Installations.Config.new([{name, "token", Resource.deployment()}]),
        offered: {__MODULE__, :offering, [agent]},
        start:
          {__MODULE__, :starting, [[config: Script.new(runner, Keyword.take(opts, [:resume]))]]},
        approvers: {__MODULE__, :approving, [Keyword.get(opts, :approvers, [])]},
        replies: replies
      )

    start_supervised!(
      {Replies,
       [name: replies, channels: channels, store: Wardrik.Test.store()] ++
         Keyword.take(opts, [:throttle, :refresh])}
    )

    :ok = DurableServer.Supervisor.wait_until_ready(replies, timeout: 10_000)
    {:ok, workspace} = Workspace.new(channels[name].context, "T1")
    {:bound, binding, _offer} = Rooms.joined(Room.new(workspace, "C1"), name: "books", by: @maria)
    itself = AgentID.resource(agent)
    on_exit(fn -> Enum.each([itself, Resource.parse!("#{itself}/*")], &Fleet.forget_under/1) end)

    {workspace, binding}
  end

  defp inbound(_workspace, fields),
    do: struct!(Inbound, [room: "C1", sender: @maria, mentioned?: true] ++ fields)

  # What is posted next in `thread`, past the statuses shown there before it.
  defp posted(thread) do
    receive do
      {:status, ^thread, _label} -> posted(thread)
      {:delivered, %Outbound{thread: ^thread, body: body}, _channel} -> body
    after
      1_000 -> flunk("nothing was posted in #{thread}")
    end
  end

  test "asks the room's agent in a thread of its own, and posts there what it answers" do
    {context, binding} = bound({AgentRunners, :echo, [self(), "Two cases of Barolo."]})

    assert {:asked, agent} =
             WardrikChannel.received(
               context,
               inbound(context, id: "1.1", text: "How much Barolo is left?")
             )

    assert agent == AgentID.put_external_id(binding.agent, "C1-1.1")
    assert agent == WardrikChannel.conversation(binding, "1.1")

    installation = context.installation

    assert_receive {:delivered,
                    %Outbound{
                      installation: ^installation,
                      room: "C1",
                      thread: "1.1",
                      body: {:reply, "Two cases of Barolo.", ["1.1"]}
                    }, _channel}

    reply = inbound(context, thread: "1.1", id: "1.2", text: "And Nebbiolo?", mentioned?: false)
    assert WardrikChannel.received(context, reply) == {:asked, agent}

    assert_receive {:delivered,
                    %Outbound{thread: "1.1", body: {:reply, "Two cases of Barolo.", ["1.2"]}},
                    _channel}

    assert_receive {:turn, turn}
    assert {:user, "From maria (channel slack/T1/U1):\nHow much Barolo is left?"} in turn
  end

  test "leaves alone what the room's agent does not answer" do
    {context, binding} = bound({AgentRunners, :echo, [self(), "Here."]})

    unbound = %{inbound(context, id: "2.1", text: "Anyone?") | room: "C2"}
    assert WardrikChannel.received(context, unbound) == :ignored

    unmentioned = inbound(context, id: "2.2", text: "Lunch?", mentioned?: false)
    assert WardrikChannel.received(context, unmentioned) == :ignored

    elsewhere = inbound(context, thread: "2.2", id: "2.3", text: "Pizza.", mentioned?: false)
    assert WardrikChannel.received(context, elsewhere) == :ignored

    refute Fleet.stored?(WardrikChannel.conversation(binding, "2.2"))

    {:ok, %Binding{answers: :everything}, _offer} =
      Rooms.answers(Room.new(context, "C1"), :everything, by: @maria)

    assert {:asked, _agent} = WardrikChannel.received(context, unmentioned)
    assert_receive {:delivered, %Outbound{thread: "2.2", body: {:reply, "Here.", ["2.2"]}}, _}
  end

  test "asks the channel's approvers directly the calls a thread's run waits on" do
    {context, _room} = bound({AgentRunners, :parking, [self(), "call_1"]}, approvers: ["@maria"])

    assert {:asked, agent} =
             WardrikChannel.received(context, inbound(context, id: "3.1", text: "Ship it."))

    assert_receive {:delivered,
                    %Outbound{
                      thread: "3.1",
                      body: {:notice, %Notice{kind: :parked, agent: ^agent, calls: [call]}},
                      approvers: ["@maria"],
                      to: :approvers
                    }, _channel}

    assert %{id: "call_1", name: "deploy"} = call

    nudge = inbound(context, thread: "3.1", id: "3.2", text: "Well?", mentioned?: false)
    assert WardrikChannel.received(context, nudge) == {:asked, agent}

    assert_receive {:delivered,
                    %Outbound{thread: "3.1", body: {:notice, _parked}, to: :approvers}, _channel}
  end

  test "posts again what a thread's agent waits on, for a message that waits behind it" do
    {context, _room} = bound({AgentRunners, :parking, [self(), "call_1"]})

    assert {:asked, agent} =
             WardrikChannel.received(context, inbound(context, id: "3.1", text: "Ship it."))

    assert_receive :asked

    assert_receive {:delivered,
                    %Outbound{body: {:notice, %Notice{kind: :parked}}, approvers: [], to: :room},
                    _channel}

    nudge = inbound(context, thread: "3.1", id: "3.2", text: "Well?", mentioned?: false)
    assert WardrikChannel.received(context, nudge) == {:asked, agent}

    assert_receive {:delivered,
                    %Outbound{
                      thread: "3.1",
                      body: {:notice, %Notice{kind: :parked, calls: [%{id: "call_1"}]}}
                    }, _channel}

    refute_receive :asked, 200
  end

  test "reminds nothing in a room it does not post in, nor a thread it does not follow" do
    {:ok, nowhere} =
      Workspace.new(
        %Context{
          host: Wardrik.Host.new(store: Wardrik.Test.store()),
          channel: "chat-none",
          installations: Installations.Config.new([{"chat-none", "token", Resource.deployment()}])
        },
        "T1"
      )

    assert Replies.remind(Room.new(nowhere, "C1"), "1.1") == :ok

    {context, _room} = bound({AgentRunners, :echo, [self(), "Here."]})
    {:asked, _agent} = WardrikChannel.received(context, inbound(context, id: "8.1", text: "Hi."))
    assert_receive {:delivered, %Outbound{body: {:reply, "Here.", ["8.1"]}}, _channel}

    assert Replies.remind(Room.new(context, "C1"), "9.9") == :ok
    refute_receive {:delivered, _outbound, _channel}, 200
  end

  test "says in the thread that an account a call waited on was connected, and carries on" do
    link = %{url: "https://github.com/login/oauth", code: nil}
    credential = %{ref: "github", owner: {"test", nil}}
    answer = {:ok, [Wardrik.Conversation.Assistant.new("Opened.")]}

    {context, _room} =
      bound({AgentRunners, :connecting, [self(), "call_1", link, credential]},
        resume: {AgentRunners, :resuming, [self(), answer]}
      )

    assert {:asked, _agent} =
             WardrikChannel.received(context, inbound(context, id: "9.1", text: "File it."))

    assert_receive {:delivered,
                    %Outbound{body: {:notice, %Notice{kind: :parked, calls: [connecting]}}},
                    _channel}

    assert connecting.authorization

    by = Wardrik.Principal.new(:oauth, "github", name: "github authorization")
    :ok = Wardrik.Credential.available("github", {"test", nil}, by: by)

    assert_receive {:delivered, %Outbound{thread: "9.1", body: {:reply, "Connected github.", []}},
                    _channel}

    assert_receive {:delivered, %Outbound{thread: "9.1", body: {:reply, "Opened.", ["9.1"]}},
                    _channel}
  end

  test "says in the thread who decided a call it waited on" do
    {context, _room} = bound({AgentRunners, :parking, [self(), "call_1"]})

    assert {:asked, agent} =
             WardrikChannel.received(context, inbound(context, id: "5.1", text: "Ship it."))

    assert_receive {:delivered, %Outbound{body: {:notice, %Notice{kind: :parked}}}, _channel}

    by = Wardrik.Principal.new(:channel, "slack/T1/U1", name: "maria")

    :ok =
      Wardrik.Agent.decide(
        agent,
        %{"call_1" => {:deny, "Not on Fridays."}},
        token: Wardrik.Token.root(by),
        host: Wardrik.Host.new(store: Wardrik.Test.store())
      )

    assert_receive {:delivered,
                    %Outbound{
                      thread: "5.1",
                      body: {:reply, "Denied by maria: Not on Fridays.", []}
                    }, _channel}
  end

  test "posts why a thread's run failed" do
    {context, _room} = bound({AgentRunners, :failing, ["The cellar is locked."]})

    assert {:asked, _agent} =
             WardrikChannel.received(context, inbound(context, id: "4.1", text: "Count it."))

    assert_receive {:delivered,
                    %Outbound{
                      thread: "4.1",
                      body: {:notice, %Notice{kind: :failed, reason: reason}}
                    }, _channel}

    assert reason =~ "The cellar is locked."
  end

  test "asks nothing for someone the host's token allows no ask, and says so" do
    {context, binding} = bound({AgentRunners, :echo, [self(), "Here."]})
    stranger = Principal.new(:channel, "slack/T1/U9", name: "stranger")

    assert {:error, message} =
             WardrikChannel.received(context, %{
               inbound(context, id: "6.1", text: "Hello?")
               | sender: stranger
             })

    assert message == "#{binding.agent} is not one you may reach from here."
    refute Fleet.stored?(WardrikChannel.conversation(binding, "6.1"))
  end

  test "says why where the thread's agent cannot be started" do
    {context, _room} = bound({AgentRunners, :echo, [self(), "Here."]})
    context = %{context | context: %{context.context | start: {Context, :unstarted, []}}}

    assert {:error, message} =
             WardrikChannel.received(context, inbound(context, id: "5.1", text: "Hello?"))

    assert message =~ "is not running"
  end

  test "tries a refused post again until the channel takes it" do
    {:ok, refusals} = Agent.start_link(fn -> 1 end)
    {context, _room} = bound({AgentRunners, :echo, [self(), "Later."]}, refusals: refusals)

    assert {:asked, _agent} =
             WardrikChannel.received(context, inbound(context, id: "6.1", text: "Now?"))

    assert_receive {:refused, %Outbound{thread: "6.1"}}

    assert_receive {:delivered, %Outbound{thread: "6.1", body: {:reply, "Later.", ["6.1"]}}, _},
                   3_000
  end

  test "posts what was answered while it was stopped, from where it had posted" do
    {context, binding} = bound({AgentRunners, :echo, [self(), "Counted."]})

    assert {:asked, agent} =
             WardrikChannel.received(context, inbound(context, id: "7.1", text: "Count it."))

    assert_receive {:delivered, %Outbound{body: {:reply, "Counted.", ["7.1"]}}, _channel}

    channel = context.installation.channel
    key = "#{channel}/#{channel}/C1"
    :ok = DurableServer.Supervisor.terminate_child_permanent(context.context.replies, key)

    :ok = Wardrik.Agent.ask(agent, "Again.", id: "7.2", host: Wardrik.Test.host())
    assert_receive {:turn, _context}
    refute_receive {:delivered, _outbound, _channel}, 200

    :ok =
      Replies.follow(Room.new(context, "C1"), "7.1", WardrikChannel.conversation(binding, "7.1"))

    assert_receive {:delivered, %Outbound{thread: "7.1", body: {:reply, "Counted.", ["7.2"]}},
                    _channel}

    refute_receive {:delivered, %Outbound{body: {:reply, _text, ["7.1"]}}, _channel}, 200
  end

  test "shows what a thread's agent is doing, and the latest change once it may change" do
    {context, _binding} = bound({__MODULE__, :working, [self()]}, throttle: 500)

    assert {:asked, _agent} =
             WardrikChannel.received(context, inbound(context, id: "10.1", text: "Look."))

    assert_receive {:working, turn}
    assert_receive {:status, "10.1", "thinking"}

    send(turn, {:call, "web_search"})
    send(turn, {:call, "fetch_page"})
    assert_receive {:status, "10.1", "running web_search and fetch_page"}
    refute_received {:status, "10.1", "running web_search"}

    send(turn, :release)
    assert posted("10.1") == {:reply, "Done.", ["10.1"]}
  end

  test "shows a status again while it stands, and nothing once the agent is idle" do
    {context, _binding} = bound({__MODULE__, :working, [self()]}, throttle: 50, refresh: 150)

    assert {:asked, _agent} =
             WardrikChannel.received(context, inbound(context, id: "11.1", text: "Look."))

    assert_receive {:working, turn}

    for _shown <- 1..3, do: assert_receive({:status, "11.1", "thinking"})

    send(turn, :release)
    assert posted("11.1") == {:reply, "Done.", ["11.1"]}
    refute_receive {:status, "11.1", _label}, 400
  end

  test "shows a status again once what is posted in the thread takes it away" do
    {context, _binding} = bound({__MODULE__, :working, [self()]}, throttle: 300)

    assert {:asked, _agent} =
             WardrikChannel.received(context, inbound(context, id: "12.1", text: "Look."))

    assert_receive {:working, first}
    assert_receive {:status, "12.1", "thinking"}

    more = inbound(context, thread: "12.1", id: "12.2", text: "And this.", mentioned?: false)
    assert {:asked, _agent} = WardrikChannel.received(context, more)
    send(first, :release)
    assert posted("12.1") == {:reply, "Done.", ["12.1"]}

    assert_receive {:working, second}
    assert_receive {:status, "12.1", "thinking"}
    send(second, :release)
    assert posted("12.1") == {:reply, "Done.", ["12.2"]}
  end

  test "shows nothing while the agent waits on a person" do
    {context, _room} = bound({AgentRunners, :parking, [self(), "call_1"]}, throttle: 50)

    assert {:asked, _agent} =
             WardrikChannel.received(context, inbound(context, id: "13.1", text: "Ship it."))

    assert {:notice, %Notice{kind: :parked}} = posted("13.1")
    refute_receive {:status, "13.1", _label}, 200
  end

  test "says a stopped run stopped, and shows nothing more" do
    {context, _binding} = bound({__MODULE__, :working, [self()]}, throttle: 50)

    assert {:asked, agent} =
             WardrikChannel.received(context, inbound(context, id: "14.1", text: "Look."))

    assert_receive {:working, _turn}
    assert_receive {:status, "14.1", "thinking"}

    :ok = Wardrik.Agent.interrupt(agent)
    assert posted("14.1") == {:stopped, ["14.1"]}
    refute_receive {:status, "14.1", _label}, 200
  end

  test "passes over a status the channel refuses, and shows the next change" do
    {context, _binding} = bound({__MODULE__, :working, [self()]}, unshown: true, throttle: 50)

    assert {:asked, _agent} =
             WardrikChannel.received(context, inbound(context, id: "15.1", text: "Look."))

    assert_receive {:working, turn}
    assert_receive {:status, "15.1", "thinking"}
    refute_receive {:status, "15.1", "thinking"}, 200

    send(turn, {:call, "web_search"})
    assert_receive {:status, "15.1", "running web_search"}

    send(turn, :release)
    assert_receive {:delivered, %Outbound{body: {:reply, "Done.", ["15.1"]}}, _channel}, 500
  end
end
