defmodule WardrikChannel.RoomsTest do
  use ExUnit.Case, async: true

  alias Wardrik.AgentID
  alias Wardrik.Principal
  alias Wardrik.Test.Audit
  alias WardrikChannel.Context
  alias WardrikChannel.Offer
  alias WardrikChannel.Room
  alias WardrikChannel.Rooms

  @maria Principal.new(:slack, "U1", name: "maria")

  @doc false
  def offering(offers, _channel), do: offers

  @doc false
  def creatable(answer, _channel), do: answer

  @doc false
  def creating(test, channel, name, by) do
    send(test, {:created, channel, name, by})
    {:ok, %Offer{agent: AgentID.new!(name, org: "acme"), description: "Answers in ##{name}."}}
  end

  # A channel of its own per test, offering `offers`, and creating agents
  # where `create?`.
  defp context(offers, create? \\ false) do
    %Context{
      channel: "chat-#{System.unique_integer([:positive])}",
      offered: {__MODULE__, :offering, [offers]},
      creatable: {__MODULE__, :creatable, [create?]},
      create: {__MODULE__, :creating, [self()]}
    }
  end

  defp books, do: %Offer{agent: AgentID.parse!("acme/books"), description: "Keeps the books."}
  defp triage, do: %Offer{agent: AgentID.parse!("acme/triage")}

  test "binds a room to the one agent the channel offers, as the bot is invited" do
    context = context([books()])

    assert {:bound, %Room{agent: agent, answers: :mentions}, offer} =
             Rooms.joined(context, "C1", "books", @maria)

    assert agent == books().agent
    assert offer == books()
    assert %Room{room: "C1"} = Rooms.get(context, "C1")

    assert Audit.about("rooms/#{context.channel}/C1") ==
             [{"room.bound", %{"type" => "slack", "id" => "U1", "name" => "maria"}}]
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
    channel = context.channel
    assert_received {:created, ^channel, "books", @maria}
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

    assert Enum.map(Audit.about("rooms/#{context.channel}/C1"), &elem(&1, 0)) ==
             ["room.bound", "room.bound", "room.unbound"]
  end

  test "offers none, and creates none, where the host says nothing of either" do
    context = %Context{channel: "chat"}

    assert Context.offered(context) == []
    refute Context.creatable?(context)
    assert {:error, _message} = Context.create(context, "books", nil)
  end
end
