defmodule WardrikChannel.ThreadsTest do
  use ExUnit.Case, async: true

  alias Wardrik.AgentID
  alias Wardrik.AgentID.Prefix
  alias Wardrik.Fleet
  alias Wardrik.Principal
  alias Wardrik.Test.AgentRunners
  alias WardrikChannel.Approvers
  alias WardrikChannel.Context
  alias WardrikChannel.Inbound
  alias WardrikChannel.Installations
  alias WardrikChannel.Offer
  alias WardrikChannel.Outbound
  alias WardrikChannel.Place
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

  # A channel of its own, delivering to the test, posted in by a
  # WardrikChannel.Replies of its own started with it, with a room bound to
  # an agent whose threads run on `runner`, and resume on `:resumer`.
  defp bound(runner, opts \\ []) do
    agent = Wardrik.Test.Fleet.id("books")
    name = "chat-#{System.unique_integer([:positive])}"
    replies = :"replies-#{name}"

    channels =
      WardrikChannel.channels(
        [{name, {WardrikChannel.Test.Adapter, test: self(), refusals: opts[:refusals]}}],
        host:
          Wardrik.Host.new(
            store: Wardrik.Test.store(),
            grants: %WardrikChannel.Test.Grants{reach: [Principal.id(@maria)]}
          ),
        installations: Installations.Config.new([{name, "token", Prefix.all()}]),
        offered: {__MODULE__, :offering, [agent]},
        start: {__MODULE__, :starting, [[runner: runner] ++ Keyword.take(opts, [:resumer])]},
        approvers: {__MODULE__, :approving, [Keyword.get(opts, :approvers, [])]},
        replies: replies
      )

    start_supervised!({Replies, name: replies, channels: channels, store: Wardrik.Test.store()})
    :ok = DurableServer.Supervisor.wait_until_ready(replies, timeout: 10_000)
    {:ok, workspace} = Workspace.new(channels[name].context, "T1")
    {:bound, room, _offer} = Rooms.joined(Place.new(workspace, "C1"), name: "books", by: @maria)
    on_exit(fn -> Fleet.forget_under(AgentID.Prefix.of(agent)) end)

    {workspace, room}
  end

  defp inbound(_workspace, fields),
    do: struct!(Inbound, [room: "C1", sender: @maria, mentioned?: true] ++ fields)

  test "asks the room's agent in a thread of its own, and posts there what it answers" do
    {context, room} = bound({AgentRunners, :echo, [self(), "Two cases of Barolo."]})

    assert {:asked, agent} =
             WardrikChannel.received(
               context,
               inbound(context, id: "1.1", text: "How much Barolo is left?")
             )

    assert agent == AgentID.put_external_id(room.agent, "C1-1.1")
    assert agent == WardrikChannel.conversation(room, "1.1")

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
    {context, room} = bound({AgentRunners, :echo, [self(), "Here."]})

    unbound = %{inbound(context, id: "2.1", text: "Anyone?") | room: "C2"}
    assert WardrikChannel.received(context, unbound) == :ignored

    unmentioned = inbound(context, id: "2.2", text: "Lunch?", mentioned?: false)
    assert WardrikChannel.received(context, unmentioned) == :ignored

    elsewhere = inbound(context, thread: "2.2", id: "2.3", text: "Pizza.", mentioned?: false)
    assert WardrikChannel.received(context, elsewhere) == :ignored

    refute Fleet.stored?(WardrikChannel.conversation(room, "2.2"))

    {:ok, %Room{answers: :everything}, _offer} =
      Rooms.answers(Place.new(context, "C1"), :everything, by: @maria)

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
          installations: Installations.Config.new([{"chat-none", "token", Prefix.all()}])
        },
        "T1"
      )

    assert Replies.remind(Place.new(nowhere, "C1"), "1.1") == :ok

    {context, _room} = bound({AgentRunners, :echo, [self(), "Here."]})
    {:asked, _agent} = WardrikChannel.received(context, inbound(context, id: "8.1", text: "Hi."))
    assert_receive {:delivered, %Outbound{body: {:reply, "Here.", ["8.1"]}}, _channel}

    assert Replies.remind(Place.new(context, "C1"), "9.9") == :ok
    refute_receive {:delivered, _outbound, _channel}, 200
  end

  test "says in the thread that an account a call waited on was connected, and carries on" do
    link = %{url: "https://github.com/login/oauth", code: nil}
    credential = %{ref: "github", owner: {"test", nil}}
    answer = {:ok, [ReqLLM.Context.assistant("Opened.")]}

    {context, _room} =
      bound({AgentRunners, :connecting, [self(), "call_1", link, credential]},
        resumer: {AgentRunners, :resuming, [self(), answer]}
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
        Wardrik.Caller.root(principal: by, host: Wardrik.Host.new(store: Wardrik.Test.store()))
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

  test "asks nothing for someone the host's grants give no reach, and says so" do
    {context, room} = bound({AgentRunners, :echo, [self(), "Here."]})
    stranger = Principal.new(:channel, "slack/T1/U9", name: "stranger")

    assert {:error, message} =
             WardrikChannel.received(context, %{
               inbound(context, id: "6.1", text: "Hello?")
               | sender: stranger
             })

    assert message == "#{room.agent} is not one you may reach from here."
    refute Fleet.stored?(WardrikChannel.conversation(room, "6.1"))
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
    {context, room} = bound({AgentRunners, :echo, [self(), "Counted."]})

    assert {:asked, agent} =
             WardrikChannel.received(context, inbound(context, id: "7.1", text: "Count it."))

    assert_receive {:delivered, %Outbound{body: {:reply, "Counted.", ["7.1"]}}, _channel}

    channel = context.installation.channel
    key = "#{channel}/#{channel}/C1"
    :ok = DurableServer.Supervisor.terminate_child_permanent(context.context.replies, key)

    :ok = Wardrik.Agent.ask(agent, "Again.", id: "7.2")
    assert_receive {:turn, _context}
    refute_receive {:delivered, _outbound, _channel}, 200

    :ok =
      Replies.follow(Place.new(context, "C1"), "7.1", WardrikChannel.conversation(room, "7.1"))

    assert_receive {:delivered, %Outbound{thread: "7.1", body: {:reply, "Counted.", ["7.2"]}},
                    _channel}

    refute_receive {:delivered, %Outbound{body: {:reply, _text, ["7.1"]}}, _channel}, 200
  end
end
