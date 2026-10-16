defmodule Wardrik.DeploymentOperationsTest do
  # The audit is one for the node, which these tests read.
  use ExUnit.Case, async: false

  import Wardrik.Test, only: [store: 0]

  alias Wardrik.AgentID.Prefix
  alias Wardrik.Caller
  alias Wardrik.Command
  alias Wardrik.Deployment.Nodes
  alias Wardrik.Error
  alias Wardrik.Event.Log.Entry
  alias Wardrik.Grant
  alias Wardrik.Host
  alias Wardrik.Operations.CreateToken
  alias Wardrik.Operations.ListTokens
  alias Wardrik.Operations.ReadAudit
  alias Wardrik.Operations.ReadNodes
  alias Wardrik.Operations.Reload
  alias Wardrik.Operations.RevokeToken
  alias Wardrik.Principal
  alias Wardrik.Query
  alias Wardrik.Test.Audit
  alias Wardrik.Test.Fleet
  alias Wardrik.Tokens.Token

  # Reads its definitions again by telling the test that asked.
  defmodule Reloads do
    @moduledoc false
    defstruct []
    def put(_definitions, _id, _opts), do: {:error, "keeps none"}

    def reload(_definitions) do
      send(:persistent_term.get({__MODULE__, :test}), :reloaded)
      :ok
    end

    def reloading(_definitions), do: [node()]
  end

  defimpl Wardrik.Definition, for: Reloads do
    use Wardrik.Definition.None
    defdelegate put(a0, a1, a2), to: Reloads
    defdelegate reload(a0), to: Reloads
    defdelegate reloading(a0), to: Reloads
  end

  # Keeps its tokens in the store, each with the secret "secret-" and its id.
  defmodule Tokens do
    @moduledoc false
    defstruct []

    @ns :deployment_operations_test_tokens
    def create(_tokens, "refused", _opts), do: {:error, "No token is named refused."}

    def create(_tokens, name, grant: grant, for: for) do
      id = Wardrik.UUID.v7()

      token = %Token{
        id: id,
        name: name,
        grant: grant,
        principal: for,
        created_at: DateTime.utc_now()
      }

      {:ok, _vsn} = WardrikStore.put(store(), @ns, id, token)
      {:ok, %{token | secret: "secret-" <> id}}
    end

    def list(_tokens),
      do: store() |> WardrikStore.keys(@ns, "") |> Enum.map(&WardrikStore.get(store(), @ns, &1))

    def revoke(_tokens, id) do
      if WardrikStore.get(store(), @ns, id),
        do: WardrikStore.delete(store(), @ns, id),
        else: {:error, :not_found}
    end
  end

  defimpl Wardrik.Tokens, for: Tokens do
    defdelegate create(a0, a1, a2), to: Tokens
    defdelegate list(a0), to: Tokens
    defdelegate revoke(a0, a1), to: Tokens
  end

  defp host, do: Wardrik.Test.host(definitions: %Reloads{}, tokens: %Tokens{})

  defp root(host \\ host()),
    do: Caller.root(principal: Principal.new(:user, "jon", name: "Jon"), host: host)

  defp caller do
    {:ok, grant} = Grant.new(Prefix.parse!("test/"), Grant.actions())
    Caller.new(principal: Principal.new(:user, "jon", name: "Jon"), grant: grant, host: host())
  end

  describe "reloading" do
    test "reads the definitions again on every node whose host reads them, and records it" do
      :persistent_term.put({Reloads, :test}, self())

      assert {:ok, change} = Command.plan(%Reload{}, root())
      assert Command.preview(change) == %{"reloading" => %{"nodes" => [to_string(node())]}}
      refute_received :reloaded

      assert {:ok, [node]} = Command.make(change, root())
      assert node == node()
      assert Reload.render([node]) == %{"reloaded" => [to_string(node)]}
      assert_received :reloaded
      assert Enum.any?(Audit.about("agents"), &match?({"agents.reloaded", %{"id" => "jon"}}, &1))

      assert {:error, %Error{type: :forbidden}} = Command.plan(%Reload{}, caller())
    end

    test "is unsupported where no node's host reads its definitions again" do
      assert {:error, %Error{type: :unsupported}} = Command.run(%Reload{}, root(Host.new()))
    end
  end

  describe "the nodes" do
    test "count the agents running on each, and those asleep" do
      {_id, _agent} = Fleet.start_agent()

      assert {:ok, %Nodes{nodes: [{node, agents}], asleep: asleep} = nodes} =
               Query.run(%ReadNodes{}, root())

      assert node == node()
      assert agents >= 1
      assert is_integer(asleep)

      assert ReadNodes.render(nodes) == %{
               "nodes" => [%{"name" => to_string(node), "agents" => agents}],
               "asleep" => asleep
             }

      assert {:error, %Error{type: :forbidden}} = Query.run(%ReadNodes{}, caller())
    end
  end

  describe "the audit" do
    test "reads a page of the changes after a sequence number" do
      :ok = Wardrik.Audit.record(Wardrik.Audit, {:agents_reloaded, [node()]}, by: nil)
      [%{"sequence" => last} | _rest] = Enum.reverse(Audit.all())
      last = String.to_integer(last)

      assert {:ok,
              [%Entry{sequence: ^last, event: %{"type" => "wardrik.agents.reloaded"}}] = read} =
               Query.run(%ReadAudit{starting_after: last - 1, limit: 1}, root())

      assert %{"changes" => [%{"type" => "wardrik.agents.reloaded"}]} = ReadAudit.render(read)
      assert {:ok, []} = Query.run(%ReadAudit{starting_after: last, limit: 10}, root())

      assert {:error, %Error{type: :forbidden}} =
               Query.run(%ReadAudit{limit: 10}, caller())
    end
  end

  describe "tokens" do
    test "are made, listed and revoked through the host's module, and recorded" do
      {:ok, grant} = Grant.new(Prefix.parse!("test/"), [:read])
      request = %CreateToken{name: "ci", grant: grant, for: Principal.new(:user, "ana")}

      assert {:ok, change} = Command.plan(request, root())

      assert Command.preview(change) == %{
               "creating_token" => %{
                 "name" => "ci",
                 "scope" => "test/",
                 "can" => ["read"],
                 "for" => "ana"
               }
             }

      assert {:created, %Token{secret: "secret-" <> id} = made} = Command.make(change, root())
      assert %{"secret" => "secret-" <> ^id, "token" => token} = CreateToken.render(made)
      refute inspect(made) =~ "secret-"

      assert %{"id" => ^id, "name" => "ci", "scope" => "test/", "can" => ["read"], "for" => "ana"} =
               token

      refute Map.has_key?(token, "ceiling")
      assert [{"token.created", %{"id" => "jon"}}] = Audit.about("tokens/" <> id)

      assert {:ok, tokens} = Query.run(%ListTokens{}, root())
      assert Enum.any?(tokens, &(&1.id == id))
      assert %{"tokens" => [_ | _]} = ListTokens.render(tokens)

      assert {:ok, nil} = Command.run(%RevokeToken{id: id}, root())
      assert [_created, {"token.revoked", _actor}] = Audit.about("tokens/" <> id)

      assert {:error, %Error{type: :not_found}} = Command.run(%RevokeToken{id: id}, root())

      assert {:error, %Error{type: :invalid, message: "No token is named refused."}} =
               Command.run(%{request | name: "refused"}, root())

      assert {:error, %Error{type: :forbidden}} = Command.run(request, caller())
      assert {:error, %Error{type: :forbidden}} = Query.run(%ListTokens{}, caller())
    end

    test "for a person reach their own agents, or what names nobody's, never another's" do
      ana = Principal.new(:user, "ana")

      for scope <- ["test/@ana/", "test/@ana/triage", "test/", ""] do
        {:ok, grant} = Grant.new(Prefix.parse!(scope), [:read])
        request = %CreateToken{name: "ok", grant: grant, for: ana}
        assert {:ok, _change} = Command.plan(request, root())
      end

      {:ok, grant} = Grant.new(Prefix.parse!("test/@jon/"), [:read])

      assert {:error, %Error{type: :invalid, message: message}} =
               Command.plan(%CreateToken{name: "theirs", grant: grant, for: ana}, root())

      assert message == "A token for ana cannot reach test/@jon/, which is jon's."
    end

    test "are unsupported where the host makes none" do
      {:ok, grant} = Grant.new(Prefix.parse!("test/"), [:read])

      none = root(Host.new())

      assert {:error, %Error{type: :unsupported}} =
               Command.run(%CreateToken{name: "ci", grant: grant}, none)

      assert {:error, %Error{type: :unsupported}} = Query.run(%ListTokens{}, none)
      assert {:error, %Error{type: :unsupported}} = Command.run(%RevokeToken{id: "x"}, none)
    end
  end
end
