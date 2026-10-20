defmodule WardrikChannel.RoomsTest do
  use ExUnit.Case, async: true

  alias Wardrik.AgentID
  alias Wardrik.Principal
  alias Wardrik.Resource
  alias Wardrik.Test.Audit
  alias WardrikChannel.Approvers
  alias WardrikChannel.Binding
  alias WardrikChannel.Inbound
  alias WardrikChannel.Installation
  alias WardrikChannel.Installations
  alias WardrikChannel.Offer
  alias WardrikChannel.Room
  alias WardrikChannel.Rooms
  alias WardrikChannel.Test.Defined
  alias WardrikChannel.Workspace

  @maria Principal.new("slack:T1/U1", name: "maria")
  @nobody %Approvers.Named{names: []}

  setup do
    org = "acme-#{System.unique_integer([:positive])}"
    on_exit(fn -> Wardrik.Fleet.forget_under(Resource.parse!(org <> "/*")) end)
    %{org: org, channel: "chat-#{System.unique_integer([:positive])}"}
  end

  # A workspace of the test's channel, offering the agents of the test's
  # org `offers` define in it, and creating agents where `create?`.
  defp context(test, offers, create? \\ false) do
    {:ok, careful} = WardrikPolicy.decode(%{"ask" => ["*"]})
    defaults = %{"model" => "anthropic:claude-sonnet-5", "policy" => "careful"}

    host =
      Defined.host(
        policies: %{"careful" => careful},
        defaults: if(create?, do: defaults, else: Map.delete(defaults, "policy"))
      )

    for %Offer{agent: agent, description: description} <- offers,
        do:
          Defined.define(host, agent, %{
            "channels" => [test.channel],
            "description" => description
          })

    test.channel
    |> context_of(
      host: host,
      org: test.org,
      installations:
        Installations.Config.new([{test.channel, "token", Resource.parse!("*"), @nobody}])
    )
    |> workspace()
  end

  # The context of the channel `name`, as `WardrikChannel.channels/2` makes
  # it from `settings` on their `:host`.
  defp context_of(name, settings) do
    {host, settings} = Keyword.pop!(settings, :host)
    adapter = {WardrikChannel.Test.Adapter, test: self()}

    %{^name => channel} =
      WardrikChannel.channels([channels: [{name, adapter}]] ++ settings, host: host)

    channel.context
  end

  # The workspaces T1, T2… of the `:channel` `settings` name, each
  # installed for the next of `owners`, naming no approvers.
  defp installed(owners, settings) do
    installations = %WardrikChannel.Test.Installations{
      agent: start_supervised!({Agent, fn -> %{} end})
    }

    {channel, settings} = Keyword.pop!(settings, :channel)
    context = context_of(channel, [installations: installations] ++ settings)

    for {owner, n} <- Enum.with_index(owners, 1) do
      :ok =
        Installations.put(installations, %Installation{
          channel: context.channel,
          workspace: "T#{n}",
          owner: Resource.parse!(owner),
          token: "token-T#{n}",
          approvers: @nobody
        })

      {:ok, workspace} = Workspace.new(context, "T#{n}")
      workspace
    end
  end

  defp workspace(context) do
    {:ok, workspace} = Workspace.new(context, "T1")
    workspace
  end

  defp books(test),
    do: %Offer{agent: AgentID.new!("books", org: test.org), description: "Keeps the books."}

  defp triage(test), do: %Offer{agent: AgentID.new!("triage", org: test.org)}

  test "binds a room to the one agent the channel offers, as the bot is invited", test do
    context = context(test, [books(test)])

    assert {:bound, %Binding{agent: agent, answers: :mentions}, offer} =
             Rooms.joined(Room.new(context, "C1"), name: "books", by: @maria)

    assert agent == books(test).agent
    assert offer == books(test)
    channel = context.installation.channel

    assert %Binding{channel: ^channel, workspace: ^channel, room: "C1"} =
             Rooms.get(Room.new(context, "C1"))

    assert Audit.about("rooms/#{channel}/C1") ==
             [{"room.bound", %{"id" => "slack:T1/U1", "name" => "maria"}}]
  end

  test "answers the agents to choose among, and binds the one chosen", test do
    context = context(test, [books(test), triage(test)])

    assert Rooms.joined(Room.new(context, "C1"), name: "ops", by: @maria) ==
             {:choose, [books(test), triage(test)]}

    assert Rooms.get(Room.new(context, "C1")) == nil

    assert {:ok, %Binding{agent: agent}, offer} =
             Rooms.chose(Room.new(context, "C1"), triage(test).agent, by: @maria)

    assert agent == triage(test).agent
    assert offer == triage(test)

    assert Rooms.chose(Room.new(context, "C1"), AgentID.parse!("acme/other"), by: @maria) ==
             {:error, :not_offered}

    assert Rooms.choices(Room.new(context, "C1"), name: "ops") ==
             {:choose, [books(test), triage(test)]}

    elsewhere = %{context | context: %{context.context | orgs: ["globex"]}}
    assert Rooms.choices(Room.new(elsewhere, "C2"), name: "ops") == :none
  end

  test "offers to create an agent where none is offered and one may be, and creates it",
       test do
    context = context(test, [], true)

    assert Rooms.joined(Room.new(context, "C1"), name: "books", by: @maria) == {:create, "books"}
    assert Rooms.choices(Room.new(context, "C1"), name: "Books!") == {:create, "Books!"}

    assert {:ok, %Binding{agent: agent}, %Offer{description: "Answers in #Books!."}} =
             Rooms.create(Room.new(context, "C1"), "Books!", by: @maria)

    assert agent == AgentID.new!("books", org: test.org)

    assert {:ok, %Wardrik.Definition{channels: [channel], policy: "careful"}} =
             Wardrik.Definitions.get(Wardrik.Host.definitions(context.context.host), agent)

    assert channel == test.channel
    assert Wardrik.Fleet.lookup(agent, host: context.context.host)
    assert [{"agent.defined", %{"name" => "maria"}}] = Audit.about(agent)

    assert {:error, message} = Workspace.create(context, "books", by: @maria)
    assert message =~ "#{agent} is there already"
    assert {:error, "\"!!!\" makes no agent's name."} = Workspace.create(context, "!!!")

    named = %{context | context: %{context.context | orgs: ["globex-#{test.org}"]}}
    assert {:ok, %Offer{agent: %AgentID{org: "globex-" <> _}}} = Workspace.create(named, "x")
    on_exit(fn -> Wardrik.Fleet.forget_under(Resource.parse!("globex-#{test.org}/*")) end)
  end

  test "says there is nothing to offer where none is and none may be created", test do
    context = context(test, [])

    assert Rooms.joined(Room.new(context, "C1"), name: "books", by: @maria) == :none

    assert {:error, "Agents are not created from here" <> _} =
             Rooms.create(Room.new(context, "C1"), "books", by: @maria)

    closed = %{context(test, [], true) | context: %{context.context | creates: false}}
    refute Workspace.creatable?(closed)
  end

  test "changes when the agent answers, and forgets the room as the bot leaves it", test do
    context = context(test, [books(test)])
    {:bound, _room, _offer} = Rooms.joined(Room.new(context, "C1"), name: "books", by: @maria)

    assert {:ok, %Binding{answers: :everything}, offer} =
             Rooms.answers(Room.new(context, "C1"), :everything, by: @maria)

    assert offer == books(test)

    assert Rooms.answers(Room.new(context, "C2"), :everything, by: @maria) ==
             {:error, :not_bound}

    assert :ok = Rooms.left(Room.new(context, "C1"))
    assert Rooms.get(Room.new(context, "C1")) == nil
    assert :ok = Rooms.left(Room.new(context, "C1"))

    assert Enum.map(Audit.about("rooms/#{context.installation.channel}/C1"), &elem(&1, 0)) ==
             ["room.bound", "room.bound", "room.unbound"]
  end

  test "offers none, creates none, and says what the daemon does where the host says nothing",
       test do
    [workspace] = installed(["*"], host: Defined.host(), channel: test.channel)

    assert Workspace.offered(workspace) == []
    refute Workspace.creatable?(workspace)
    assert Workspace.offering(workspace) =~ "by adding `channels: [#{test.channel}]`"
    assert Workspace.deciding(workspace) =~ "The channel's approvers name who else may"
  end

  test "says how an agent comes to answer, and who else decides, as the host words them",
       test do
    [workspace] =
      installed(["*"],
        host: Defined.host(),
        channel: test.channel,
        offering: "Turn on Answers in Slack in the agent's settings.",
        deciding: "Your org's admins name the approvers."
      )

    assert Workspace.offering(workspace) == "Turn on Answers in Slack in the agent's settings."
    assert Workspace.deciding(workspace) == "Your org's admins name the approvers."

    assert {:error, "Agents are not created from here. Turn on Answers in Slack" <> _} =
             Rooms.create(Room.new(workspace, "C1"), "books", by: @maria)
  end

  test "says who decides in each workspace as its installation does, of one channel", test do
    [one, two] = installed([test.org, test.org], host: Defined.host(), channel: test.channel)
    maria = %Approvers.Named{names: ["@maria"]}
    :ok = Installations.put(one.context.installations, %{two.installation | approvers: maria})

    assert Workspace.approvers(one) == @nobody
    assert {:ok, two} = Workspace.new(two.context, "T2")
    assert Workspace.approvers(two) == maria
  end

  test "keeps a room of each workspace apart, of the same id", test do
    host = Defined.host()
    Defined.define(host, books(test).agent, %{"channels" => [test.channel]})
    [one, two] = installed([test.org, test.org], host: host, channel: test.channel)
    assert :error = Workspace.new(one.context, "T3")

    {:bound, _room, _offer} = Rooms.joined(Room.new(one, "C1"), name: "books", by: @maria)
    assert %Binding{workspace: "T1"} = Rooms.get(Room.new(one, "C1"))
    assert Rooms.get(Room.new(two, "C1")) == nil
  end

  test "offers and binds in a workspace only the agents of the owner it was installed for",
       test do
    globex = "globex-#{test.org}"
    host = Defined.host()
    books = books(test).agent
    jons = AgentID.new!("triage", org: test.org, user: "jon")
    ledger = AgentID.new!("ledger", org: globex)

    for agent <- [books, jons, ledger],
        do: Defined.define(host, agent, %{"channels" => [test.channel]})

    [acme, other] = installed([test.org, globex], host: host, channel: test.channel)

    assert Enum.map(Workspace.offered(acme), & &1.agent) == [jons, books]
    assert Enum.map(Workspace.offered(other), & &1.agent) == [ledger]
    assert Rooms.chose(Room.new(other, "C1"), books, by: @maria) == {:error, :not_offered}

    assert {:bound, %Binding{agent: ^ledger}, _offer} =
             Rooms.joined(Room.new(other, "C1"), name: "ops", by: @maria)
  end

  test "creates an agent only in a workspace whose owner covers the org it is created in",
       test do
    {:ok, careful} = WardrikPolicy.decode(%{"ask" => ["*"]})

    host =
      Defined.host(
        policies: %{"careful" => careful},
        defaults: %{"model" => "anthropic:claude-sonnet-5", "policy" => "careful"}
      )

    context = [host: host, channel: test.channel, org: test.org]
    [acme, other] = installed([test.org, "globex-#{test.org}"], context)

    refute Workspace.creatable?(other)
    assert Rooms.joined(Room.new(other, "C1"), name: "books", by: @maria) == :none

    assert {:error, "Agents are not created from here" <> _} =
             Rooms.create(Room.new(other, "C1"), "books", by: @maria)

    assert Workspace.creatable?(acme)
    assert {:ok, %Binding{agent: agent}, _offer} = Rooms.create(Room.new(acme, "C1"), "books")
    assert agent == books(test).agent
  end

  test "answers in no room bound to an agent its workspace's owner does not cover", test do
    host = Defined.host()
    Defined.define(host, books(test).agent, %{"channels" => [test.channel]})
    [acme] = installed([test.org], host: host, channel: test.channel)
    {:bound, _room, _offer} = Rooms.joined(Room.new(acme, "C1"), name: "books", by: @maria)

    globex = %{acme.installation | owner: Resource.parse!("globex-#{test.org}")}
    :ok = Installations.put(acme.context.installations, globex)
    {:ok, other} = Workspace.new(acme.context, "T1")

    assert Rooms.get(Room.new(other, "C1")) == nil

    inbound = %Inbound{room: "C1", id: "1.1", sender: @maria, text: "Hi.", mentioned?: true}
    assert WardrikChannel.received(other, inbound) == :ignored
  end
end
