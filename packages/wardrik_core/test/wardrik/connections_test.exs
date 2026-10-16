defmodule Wardrik.ConnectionsTest do
  # The audit is one for the node, which these tests read.
  use ExUnit.Case, async: false

  alias Wardrik.AgentID.Prefix
  alias Wardrik.Caller
  alias Wardrik.Command
  alias Wardrik.Connections
  alias Wardrik.Connections.Connection
  alias Wardrik.Error
  alias Wardrik.Grant
  alias Wardrik.Host
  alias Wardrik.Operations.Connect
  alias Wardrik.Operations.Disconnect
  alias Wardrik.Operations.ReadConnections
  alias Wardrik.Principal
  alias Wardrik.Query
  alias Wardrik.Test.Audit

  # Offers what the test puts in its process as :offered, and holds what it
  # puts as :held, a map of owner to providers; operations run in the test's
  # process, so they read it there.
  defmodule Offered do
    @moduledoc false
    defstruct []

    def list(_connections, owner) do
      for provider <- Process.get(:offered, []),
          do: %Connection{provider: provider, held_by: held_by(provider, owner)}
    end

    defp held_by(provider, {org, _user} = person) do
      cond do
        held?(provider, person) -> :person
        held?(provider, org) -> :org
        true -> nil
      end
    end

    defp held_by(provider, org), do: if(held?(provider, org), do: :org)

    def connect(_connections, provider, owner, by: by) do
      send(self(), {:connect, provider, owner, by})

      cond do
        provider not in Process.get(:offered, []) -> {:error, :not_found}
        held?(provider, owner) -> {:ok, :held}
        true -> {:ok, %{url: "https://auth.example.com/#{provider}", code: nil}}
      end
    end

    def disconnect(_connections, provider, owner) do
      if held?(provider, owner) do
        Process.put(:held, Map.update!(Process.get(:held), owner, &List.delete(&1, provider)))
        :ok
      else
        {:error, :not_found}
      end
    end

    defp held?(provider, owner), do: provider in Map.get(Process.get(:held, %{}), owner, [])
  end

  defimpl Wardrik.Connections, for: Offered do
    defdelegate list(a0, a1), to: Offered
    defdelegate connect(a0, a1, a2, a3), to: Offered
    defdelegate disconnect(a0, a1, a2), to: Offered
  end

  setup do
    provider = "app#{System.unique_integer([:positive])}"
    Process.put(:offered, ["github", provider])
    Process.put(:held, %{{"acme", "jon"} => ["github"]})

    %{provider: provider}
  end

  @jon Principal.new(:user, "jon", name: "Jon")

  defp caller(
         scope,
         principal \\ @jon,
         can \\ Grant.actions(),
         host \\ Host.new(connections: %Offered{})
       ) do
    {:ok, grant} = Grant.new(Prefix.parse!(scope), can)
    Caller.new(principal: principal, grant: grant, host: host)
  end

  defp read(caller, whose \\ :person) do
    with {:ok, request} <- Connections.Owner.request(ReadConnections, caller, whose),
         do: Query.run(request, caller)
  end

  describe "listing" do
    test "says who holds each account offered, never a value", %{provider: provider} do
      assert {:ok, connections} = read(caller("acme/@jon/"))

      assert connections == [
               %Connection{provider: "github", held_by: :person},
               %Connection{provider: provider, held_by: nil}
             ]

      assert ReadConnections.render(connections) == %{
               "connections" => [
                 %{"provider" => "github", "held_by" => "person"},
                 %{"provider" => provider}
               ]
             }
    end

    test "is of the person a scope names, else the person the caller acts as" do
      assert {:ok, request} =
               Connections.Owner.request(ReadConnections, caller("acme/@jon/", nil), :person)

      assert to_string(request.owner) == "acme/@jon/"

      assert {:ok, request} =
               Connections.Owner.request(ReadConnections, caller("acme/*"), :person)

      assert to_string(request.owner) == "acme/@jon/"
      assert {:ok, _list} = read(caller("acme/*"))

      assert {:error, %Error{type: :not_found}} = read(caller("acme/"))

      assert {:ok, request} = Connections.Owner.request(ReadConnections, caller("acme/"), :org)
      assert to_string(request.owner) == "acme/"
    end

    test "needs a person, or the org, and one org" do
      assert {:error, %Error{type: :invalid, message: message}} =
               read(caller("acme/", Principal.new(:token, "t1")))

      assert message =~ "owner=org"
      assert {:ok, _list} = read(caller("acme/", Principal.new(:token, "t1")), :org)

      assert {:error, %Error{type: :invalid}} = read(caller(""))
    end

    test "is refused outside the caller's scope, and without read" do
      assert {:error, %Error{type: :not_found}} =
               Query.run(%ReadConnections{owner: Prefix.parse!("globex/")}, caller("acme/"))

      assert {:error, %Error{type: :not_found}} =
               Query.run(
                 %ReadConnections{owner: Prefix.parse!("acme/@jon/")},
                 caller("acme/@maria/")
               )

      assert {:error, %Error{type: :forbidden}} =
               read(caller("acme/@jon/", @jon, [:message]))
    end
  end

  describe "connecting" do
    test "answers where to authorize, or that it is held, as the caller", %{provider: provider} do
      assert {:ok, request} =
               Connections.Owner.request(Connect, caller("acme/@jon/"), :person,
                 provider: provider
               )

      assert {:ok, %Connection{authorization: %{url: "https://auth.example.com/" <> _}} = asked} =
               Command.run(request, caller("acme/@jon/"))

      assert %{"connected" => false, "authorization" => %{"url" => _url}} = Connect.render(asked)

      assert_received {:connect, ^provider, {"acme", "jon"}, @jon}

      {:ok, request} =
        Connections.Owner.request(Connect, caller("acme/@jon/"), :person, provider: "github")

      assert {:ok, %Connection{provider: "github", held_by: :person, authorization: nil} = held} =
               Command.run(request, caller("acme/@jon/"))

      assert Connect.render(held) == %{"provider" => "github", "connected" => true}
    end

    test "is refused for an account not offered, without define, or for the org without it" do
      {:ok, request} =
        Connections.Owner.request(Connect, caller("acme/@jon/"), :person, provider: "nothing")

      assert {:error, %Error{type: :not_found}} = Command.run(request, caller("acme/@jon/"))

      reader = caller("acme/", @jon, [:read])
      {:ok, request} = Connections.Owner.request(Connect, reader, :org, provider: "github")
      assert {:error, %Error{type: :forbidden}} = Command.run(request, reader)
    end
  end

  describe "disconnecting" do
    test "forgets the owner's account, and is recorded as the caller's" do
      {:ok, request} =
        Connections.Owner.request(Disconnect, caller("acme/@jon/"), :person, provider: "github")

      assert {:ok, %Connection{provider: "github", held_by: :person}} =
               Command.run(request, caller("acme/@jon/"))

      assert {"secret.removed", %{"type" => "user", "id" => "jon"}} =
               List.last(Audit.about("secrets/github"))

      assert {:ok, [%Connection{provider: "github", held_by: nil} | _]} =
               read(caller("acme/@jon/"))

      assert {:error, %Error{type: :not_found}} = Command.run(request, caller("acme/@jon/"))
    end
  end

  test "a host with no connections module offers none" do
    assert {:error, %Error{type: :unsupported}} =
             read(caller("acme/@jon/", @jon, Grant.actions(), Host.new()))
  end
end
