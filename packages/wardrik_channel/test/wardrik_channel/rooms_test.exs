defmodule WardrikChannel.RoomsTest do
  use ExUnit.Case, async: true

  alias Wardrik.AgentID
  alias Wardrik.AgentID.Prefix
  alias Wardrik.Principal
  alias Wardrik.Test.Audit
  alias WardrikChannel.Context
  alias WardrikChannel.Installation
  alias WardrikChannel.Installations
  alias WardrikChannel.Offer
  alias WardrikChannel.Room
  alias WardrikChannel.Rooms
  alias WardrikChannel.Workspace

  @maria Principal.new(:channel, "slack/T1/U1", name: "maria")

  @doc false
  def offering(offers, _channel), do: offers

  @doc false
  def creatable(answer, _channel), do: answer

  @doc false
  def creating(test, installation, name, by) do
    send(test, {:created, installation, name, by})
    {:ok, %Offer{agent: AgentID.new!(name, org: "acme"), description: "Answers in ##{name}."}}
  end

  # A workspace of a channel of its own per test, offering `offers`, and
  # creating agents where `create?`.
  defp context(offers, create? \\ false) do
    channel = "chat-#{System.unique_integer([:positive])}"

    workspace(%Context{
      host: Wardrik.Host.new(store: Wardrik.Test.store()),
      channel: channel,
      installations: Installations.Config.new([{channel, "token", Prefix.all()}]),
      offered: {__MODULE__, :offering, [offers]},
      creatable: {__MODULE__, :creatable, [create?]},
      create: {__MODULE__, :creating, [self()]}
    })
  end

  defp workspace(context) do
    {:ok, workspace} = Workspace.new(context, "T1")
    workspace
  end

  defp books, do: %Offer{agent: AgentID.parse!("acme/books"), description: "Keeps the books."}
  defp triage, do: %Offer{agent: AgentID.parse!("acme/triage")}

  test "binds a room to the one agent the channel offers, as the bot is invited" do
    context = context([books()])

    assert {:bound, %Room{agent: agent, answers: :mentions}, offer} =
             Rooms.joined(context, "C1", "books", @maria)

    assert agent == books().agent
    assert offer == books()
    channel = context.installation.channel
    assert %Room{channel: ^channel, workspace: ^channel, room: "C1"} = Rooms.get(context, "C1")

    assert Audit.about("rooms/#{channel}/C1") ==
             [{"room.bound", %{"type" => "channel", "id" => "slack/T1/U1", "name" => "maria"}}]
  end

  test "answers the agents to choose among, and binds the one chosen" do
    context = context([books(), triage()])

    assert Rooms.joined(context, "C1", "ops", @maria) == {:choose, [books(), triage()]}
    assert Rooms.get(context, "C1") == nil

    assert {:ok, %Room{agent: agent}, offer} = Rooms.chose(context, "C1", triage().agent, @maria)
    assert agent == triage().agent
    assert offer == triage()

    assert Rooms.chose(context, "C1", AgentID.parse!("acme/other"), @maria) ==
             {:error, :not_offered}

    assert Rooms.choices(context, "ops") == {:choose, [books(), triage()]}
  end

  test "offers to create an agent where none is offered and one may be, and creates it" do
    context = context([], true)

    assert Rooms.joined(context, "C1", "books", @maria) == {:create, "books"}
    assert Rooms.choices(context, "books") == {:create, "books"}

    assert {:ok, %Room{agent: agent}, %Offer{description: "Answers in #books."}} =
             Rooms.create(context, "C1", "books", @maria)

    assert agent == AgentID.parse!("acme/books")
    installation = context.installation
    assert_received {:created, ^installation, "books", @maria}
  end

  test "says there is nothing to offer where none is and none may be created" do
    context = context([])

    assert Rooms.joined(context, "C1", "books", @maria) == :none

    assert {:error, "Agents are not created from here" <> _} =
             Rooms.create(context, "C1", "books", @maria)

    refute_received {:created, _channel, _name, _by}
  end

  test "changes when the agent answers, and forgets the room as the bot leaves it" do
    context = context([books()])
    {:bound, _room, _offer} = Rooms.joined(context, "C1", "books", @maria)

    assert {:ok, %Room{answers: :everything}, offer} =
             Rooms.answers(context, "C1", :everything, @maria)

    assert offer == books()
    assert Rooms.answers(context, "C2", :everything, @maria) == {:error, :not_bound}

    assert :ok = Rooms.left(context, "C1", nil)
    assert Rooms.get(context, "C1") == nil
    assert :ok = Rooms.left(context, "C1", nil)

    assert Enum.map(Audit.about("rooms/#{context.installation.channel}/C1"), &elem(&1, 0)) ==
             ["room.bound", "room.bound", "room.unbound"]
  end

  test "offers none, creates none, and names no approvers where the host says nothing" do
    workspace = %Workspace{
      context: %Context{
        host: Wardrik.Host.new(store: Wardrik.Test.store()),
        channel: "chat",
        installations: Installations.Config.new([])
      },
      installation: %Installation{
        channel: "chat",
        workspace: "T1",
        owner: Prefix.all(),
        token: "token"
      }
    }

    assert Workspace.offered(workspace) == []
    refute Workspace.creatable?(workspace)
    assert {:error, _message} = Workspace.create(workspace, "books", nil)
    assert Workspace.approvers(workspace) == %WardrikChannel.Approvers.Named{names: []}
  end

  test "keeps a room of each workspace apart, of the same id" do
    channel = "chat-#{System.unique_integer([:positive])}"

    installations = %WardrikChannel.Test.Installations{
      agent: start_supervised!({Agent, fn -> %{} end})
    }

    for workspace <- ["T1", "T2"] do
      :ok =
        Installations.put(installations, %Installation{
          channel: channel,
          workspace: workspace,
          owner: Prefix.all(),
          token: "token-" <> workspace
        })
    end

    context = %Context{
      host: Wardrik.Host.new(store: Wardrik.Test.store()),
      channel: channel,
      installations: installations,
      offered: {__MODULE__, :offering, [[books()]]}
    }

    {:ok, one} = Workspace.new(context, "T1")
    {:ok, two} = Workspace.new(context, "T2")
    assert :error = Workspace.new(context, "T3")

    {:bound, _room, _offer} = Rooms.joined(one, "C1", "books", @maria)
    assert %Room{workspace: "T1"} = Rooms.get(one, "C1")
    assert Rooms.get(two, "C1") == nil
  end
end
