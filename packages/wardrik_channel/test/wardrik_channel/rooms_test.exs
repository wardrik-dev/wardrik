defmodule WardrikChannel.RoomsTest do
  use ExUnit.Case, async: true

  alias Wardrik.AgentID
  alias Wardrik.Principal
  alias Wardrik.Test.Audit
  alias WardrikChannel.Context
  alias WardrikChannel.Room
  alias WardrikChannel.Rooms

  @maria Principal.new(:slack, "U1", name: "maria")

  @doc false
  def offering(agents, _channel), do: agents

  # A channel of its own per test, offering `agents`.
  defp context(agents) do
    %Context{
      channel: "chat-#{System.unique_integer([:positive])}",
      offered: {__MODULE__, :offering, [agents]}
    }
  end

  defp books, do: AgentID.parse!("acme/books")
  defp triage, do: AgentID.parse!("acme/triage")

  test "binds a room to the one agent the channel offers, as the bot is invited" do
    context = context([books()])

    assert {:bound, %Room{agent: agent, answers: :mentions}} = Rooms.joined(context, "C1", @maria)
    assert agent == books()
    assert %Room{room: "C1"} = Rooms.get(context, "C1")

    assert Audit.about("rooms/#{context.channel}/C1") ==
             [{"room.bound", %{"type" => "slack", "id" => "U1", "name" => "maria"}}]
  end

  test "answers the agents to choose among, and binds the one chosen" do
    context = context([books(), triage()])

    assert Rooms.joined(context, "C1", @maria) == {:choose, [books(), triage()]}
    assert Rooms.get(context, "C1") == nil

    assert {:ok, %Room{agent: agent}} = Rooms.chose(context, "C1", triage(), @maria)
    assert agent == triage()

    assert Rooms.chose(context, "C1", AgentID.parse!("acme/other"), @maria) ==
             {:error, :not_offered}
  end

  test "says so where the channel offers no agent" do
    assert Rooms.joined(context([]), "C1", @maria) == {:choose, []}
  end

  test "changes when the agent answers, and forgets the room as the bot leaves it" do
    context = context([books()])
    {:bound, _room} = Rooms.joined(context, "C1", @maria)

    assert {:ok, %Room{answers: :everything}} = Rooms.answers(context, "C1", :everything, @maria)
    assert Rooms.answers(context, "C2", :everything, @maria) == {:error, :not_bound}

    assert :ok = Rooms.left(context, "C1", nil)
    assert Rooms.get(context, "C1") == nil
    assert :ok = Rooms.left(context, "C1", nil)

    assert Enum.map(Audit.about("rooms/#{context.channel}/C1"), &elem(&1, 0)) ==
             ["room.bound", "room.bound", "room.unbound"]
  end

  test "offers none where the host says nothing of what it offers" do
    assert Context.offered(%Context{channel: "chat"}) == []
  end
end
