defmodule Wardrik.ConnectionsTest do
  # The audit is one for the node, which these tests read.
  use ExUnit.Case, async: false

  alias Wardrik.AgentID.Prefix
  alias Wardrik.Connections.Connection
  alias Wardrik.Error
  alias Wardrik.Grant
  alias Wardrik.Host
  alias Wardrik.Principal
  alias Wardrik.Session
  alias Wardrik.Test.Audit

  # Offers what the test puts in its process as :offered, and holds what it
  # puts as :held, a map of owner to providers; the functions run in the
  # test's process, so they read it there.
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
  @mine Prefix.parse!("acme/@jon/")

  defp session(scope, can \\ Grant.actions(), host \\ Host.new(connections: %Offered{})) do
    {:ok, grant} = Grant.new(Prefix.parse!(scope), can)
    Session.new(host: host, principal: @jon, grant: grant)
  end

  describe "listing" do
    test "says who holds each account offered, never a value", %{provider: provider} do
      assert {:ok, connections} = Wardrik.connections_list(session("acme/@jon/"), @mine)

      assert connections == [
               %Connection{provider: "github", held_by: :person},
               %Connection{provider: provider, held_by: nil}
             ]
    end

    test "is refused outside the session's scope, and without read" do
      assert {:error, %Error{type: :not_found}} =
               Wardrik.connections_list(session("acme/"), Prefix.parse!("globex/"))

      assert {:error, %Error{type: :not_found}} =
               Wardrik.connections_list(session("acme/@maria/"), @mine)

      assert {:error, %Error{type: :forbidden}} =
               Wardrik.connections_list(session("acme/@jon/", [:message]), @mine)
    end

    test "is unsupported where the host offers none" do
      assert {:error, %Error{type: :unsupported}} =
               Wardrik.connections_list(session("acme/@jon/", Grant.actions(), Host.new()), @mine)
    end
  end

  describe "connecting" do
    test "answers where to authorize, or that it is held, as the session's principal",
         %{provider: provider} do
      assert {:ok, %Connection{authorization: %{url: "https://auth.example.com/" <> _}}} =
               Wardrik.connections_connect(session("acme/@jon/"), @mine, provider)

      assert_received {:connect, ^provider, {"acme", "jon"}, @jon}

      assert {:ok, %Connection{provider: "github", held_by: :person, authorization: nil}} =
               Wardrik.connections_connect(session("acme/@jon/"), @mine, "github")
    end

    test "is refused for an account not offered, or without define" do
      assert {:error, %Error{type: :not_found}} =
               Wardrik.connections_connect(session("acme/@jon/"), @mine, "nothing")

      assert {:error, %Error{type: :forbidden}} =
               Wardrik.connections_connect(
                 session("acme/", [:read]),
                 Prefix.parse!("acme/"),
                 "github"
               )
    end
  end

  test "disconnecting forgets the owner's account, recorded as the session's principal" do
    assert {:ok, %Connection{provider: "github", held_by: :person}} =
             Wardrik.connections_disconnect(session("acme/@jon/"), @mine, "github")

    assert {"secret.removed", %{"type" => "user", "id" => "jon"}} =
             List.last(Audit.about("secrets/github"))

    assert {:ok, [%Connection{provider: "github", held_by: nil} | _]} =
             Wardrik.connections_list(session("acme/@jon/"), @mine)

    assert {:error, %Error{type: :not_found}} =
             Wardrik.connections_disconnect(session("acme/@jon/"), @mine, "github")
  end
end
