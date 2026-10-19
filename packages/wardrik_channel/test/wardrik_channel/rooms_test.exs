defmodule WardrikChannel.RoomsTest do
  use ExUnit.Case, async: true

  alias Wardrik.AgentID
  alias Wardrik.Principal
  alias Wardrik.Resource
  alias Wardrik.Test.Audit
  alias WardrikChannel.Binding
  alias WardrikChannel.Context
  alias WardrikChannel.Installation
  alias WardrikChannel.Installations
  alias WardrikChannel.Offer
  alias WardrikChannel.Room
  alias WardrikChannel.Rooms
  alias WardrikChannel.Test.Defined
  alias WardrikChannel.Workspace

  @maria Principal.new(:channel, "slack/T1/U1", name: "maria")

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

    workspace(%Context{
      host: host,
      channel: test.channel,
      org: test.org,
      installations: Installations.Config.new([{test.channel, "token", Resource.deployment()}])
    })
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
             [{"room.bound", %{"type" => "channel", "id" => "slack/T1/U1", "name" => "maria"}}]
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

  test "offers none, creates none, and names no approvers where the host says nothing" do
    workspace = %Workspace{
      context: %Context{
        host: Defined.host(),
        channel: "chat-#{System.unique_integer([:positive])}",
        installations: Installations.Config.new([])
      },
      installation: %Installation{
        channel: "chat",
        workspace: "T1",
        owner: Resource.deployment(),
        token: "token"
      }
    }

    assert Workspace.offered(workspace) == []
    refute Workspace.creatable?(workspace)
    assert Workspace.approvers(workspace) == %WardrikChannel.Approvers.Named{names: []}
    assert Workspace.offering(workspace) =~ "by adding `channels: [chat-"
    assert Workspace.deciding(workspace) =~ "The channel's approvers name who else may"
  end

  test "keeps a room of each workspace apart, of the same id", test do
    channel = test.channel

    installations = %WardrikChannel.Test.Installations{
      agent: start_supervised!({Agent, fn -> %{} end})
    }

    for workspace <- ["T1", "T2"] do
      :ok =
        Installations.put(installations, %Installation{
          channel: channel,
          workspace: workspace,
          owner: Resource.deployment(),
          token: "token-" <> workspace
        })
    end

    host = Defined.host()
    Defined.define(host, books(test).agent, %{"channels" => [channel]})
    context = %Context{host: host, channel: channel, installations: installations}

    {:ok, one} = Workspace.new(context, "T1")
    {:ok, two} = Workspace.new(context, "T2")
    assert :error = Workspace.new(context, "T3")

    {:bound, _room, _offer} = Rooms.joined(Room.new(one, "C1"), name: "books", by: @maria)
    assert %Binding{workspace: "T1"} = Rooms.get(Room.new(one, "C1"))
    assert Rooms.get(Room.new(two, "C1")) == nil
  end
end
