defmodule Wardrik.DeploymentOperationsTest do
  # The audit is one for the node, which these tests read.
  use ExUnit.Case, async: false

  alias Wardrik.AgentID.Prefix
  alias Wardrik.Caller
  alias Wardrik.Command
  alias Wardrik.Error
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

  # Reads its definitions again by telling the test that asked.
  defmodule Reloads do
    @moduledoc false
    use Wardrik.Definition

    @impl true
    def put(_id, _definition, _grant), do: {:error, "keeps none"}

    @impl true
    def reload do
      send(:persistent_term.get({__MODULE__, :test}), :reloaded)
      :ok
    end

    @impl true
    def reloading, do: [node()]
  end

  # Keeps its tokens in the store, each with the secret "secret-" and its id.
  defmodule Tokens do
    @moduledoc false
    @behaviour Wardrik.Tokens

    @ns :deployment_operations_test_tokens

    @impl true
    def create("refused", _grant, _for), do: {:error, "No token is named refused."}

    def create(name, grant, for) do
      id = Wardrik.UUID.v7()
      token = %{id: id, name: name, grant: grant, principal: for, created_at: DateTime.utc_now()}
      {:ok, _vsn} = WardrikStore.put(@ns, id, token)
      {:ok, "secret-" <> id, token}
    end

    @impl true
    def list, do: @ns |> WardrikStore.keys("") |> Enum.map(&WardrikStore.get(@ns, &1))

    @impl true
    def revoke(id) do
      if WardrikStore.get(@ns, id), do: WardrikStore.delete(@ns, id), else: {:error, :not_found}
    end
  end

  @host Host.new(definitions: Reloads, tokens: Tokens)

  defp root(host \\ @host),
    do: Caller.root(principal: Principal.new(:user, "jon", name: "Jon"), host: host)

  defp caller do
    {:ok, grant} = Grant.new(Prefix.parse!("test/"), Grant.actions())
    Caller.new(principal: Principal.new(:user, "jon", name: "Jon"), grant: grant, host: @host)
  end

  describe "reloading" do
    test "reads the definitions again on every node whose host reads them, and records it" do
      :persistent_term.put({Reloads, :test}, self())

      assert {:ok, change} = Command.plan(%Reload{}, root())
      assert Command.preview(change) == %{"reloading" => %{"nodes" => [to_string(node())]}}
      refute_received :reloaded

      assert {:ok, %{"reloaded" => [node]}} = Command.make(change, root())
      assert node == to_string(node())
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

      assert {:ok, %{"nodes" => [%{"name" => name, "agents" => agents}], "asleep" => asleep}} =
               Query.run(%ReadNodes{}, root())

      assert name == to_string(node())
      assert agents >= 1
      assert is_integer(asleep)

      assert {:error, %Error{type: :forbidden}} = Query.run(%ReadNodes{}, caller())
    end
  end

  describe "the audit" do
    test "reads a page of the changes after a sequence number" do
      :ok = Wardrik.Audit.record({:agents_reloaded, [node()]}, nil)
      [%{"sequence" => last} | _rest] = Enum.reverse(Audit.all())
      last = String.to_integer(last)

      assert {:ok, %{"changes" => [%{"type" => "wardrik.agents.reloaded"}]}} =
               Query.run(%ReadAudit{starting_after: last - 1, limit: 1}, root())

      assert {:ok, %{"changes" => []}} =
               Query.run(%ReadAudit{starting_after: last, limit: 10}, root())

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

      assert {:created, %{"secret" => "secret-" <> id, "token" => token}} =
               Command.make(change, root())

      assert %{"id" => ^id, "name" => "ci", "scope" => "test/", "can" => ["read"], "for" => "ana"} =
               token

      refute Map.has_key?(token, "ceiling")
      assert [{"token.created", %{"id" => "jon"}}] = Audit.about("tokens/" <> id)

      assert {:ok, %{"tokens" => tokens}} = Query.run(%ListTokens{}, root())
      assert Enum.any?(tokens, &(&1["id"] == id))

      assert {:ok, nil} = Command.run(%RevokeToken{id: id}, root())
      assert [_created, {"token.revoked", _actor}] = Audit.about("tokens/" <> id)

      assert {:error, %Error{type: :not_found}} = Command.run(%RevokeToken{id: id}, root())

      assert {:error, %Error{type: :invalid, message: "No token is named refused."}} =
               Command.run(%{request | name: "refused"}, root())

      assert {:error, %Error{type: :forbidden}} = Command.run(request, caller())
      assert {:error, %Error{type: :forbidden}} = Query.run(%ListTokens{}, caller())
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
