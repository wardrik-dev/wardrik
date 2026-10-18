defmodule Wardrik.DeploymentTest do
  # The audit is one for the node, which these tests read.
  use ExUnit.Case, async: false

  import Wardrik.Test, only: [store: 0]

  alias Wardrik.AgentID.Prefix
  alias Wardrik.Deployment.Nodes
  alias Wardrik.Error
  alias Wardrik.Event.Log.Entry
  alias Wardrik.Grant
  alias Wardrik.Host
  alias Wardrik.Principal
  alias Wardrik.Session
  alias Wardrik.Test.Audit
  alias Wardrik.Test.Fleet
  alias Wardrik.Tokens.Token

  # Reads its definitions again by telling the test that asked.
  defmodule Reloads do
    @moduledoc false
    defstruct []
    def put(_definitions, _id, _opts), do: {:error, "keeps none"}

    def reload(_definitions, _opts) do
      send(:persistent_term.get({__MODULE__, :test}), :reloaded)
      :ok
    end

    def reloading(_definitions), do: [node()]
  end

  defimpl Wardrik.Definition, for: Reloads do
    use Wardrik.Definition.None
    defdelegate put(a0, a1, a2), to: Reloads
    defdelegate reload(a0, a1), to: Reloads
    defdelegate reloading(a0), to: Reloads
  end

  # Keeps its tokens in the store, each with the secret "secret-" and its id.
  defmodule Tokens do
    @moduledoc false
    defstruct []

    @ns :deployment_test_tokens
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
    do: Session.root(host: host, principal: Principal.new(:user, "jon", name: "Jon"))

  # A session over the agents of one org, which the deployment is not.
  defp session do
    {:ok, grant} = Grant.new(Prefix.parse!("test/"), Grant.actions())
    Session.new(host: host(), principal: Principal.new(:user, "jon", name: "Jon"), grant: grant)
  end

  describe "reloading" do
    test "reads the definitions again on every node whose host reads them, and records it" do
      :persistent_term.put({Reloads, :test}, self())

      assert {:ok, [node]} = Wardrik.deployment_reload(root())
      assert node == node()
      assert_received :reloaded
      assert Enum.any?(Audit.about("agents"), &match?({"agents.reloaded", %{"id" => "jon"}}, &1))

      assert {:error, %Error{type: :forbidden}} = Wardrik.deployment_reload(session())
    end

    test "is unsupported where no node's host reads its definitions again" do
      assert {:error, %Error{type: :unsupported}} = Wardrik.deployment_reload(root(Host.new()))
    end
  end

  test "the nodes count the agents running on each, and those asleep" do
    {_id, _agent} = Fleet.start_agent()

    assert {:ok, %Nodes{nodes: [{node, agents}], asleep: asleep}} =
             Wardrik.deployment_nodes(root())

    assert node == node()
    assert agents >= 1
    assert is_integer(asleep)
    assert {:error, %Error{type: :forbidden}} = Wardrik.deployment_nodes(session())
  end

  test "the audit reads a page of the changes after a sequence number" do
    :ok = Wardrik.Audit.record(Wardrik.Audit, {:agents_reloaded, [node()]}, by: nil)
    [%{"sequence" => last} | _rest] = Enum.reverse(Audit.all())
    last = String.to_integer(last)

    assert {:ok, [%Entry{sequence: ^last, event: %{"type" => "wardrik.agents.reloaded"}}]} =
             Wardrik.deployment_audit(root(), after: last - 1, limit: 1)

    assert {:ok, []} = Wardrik.deployment_audit(root(), after: last, limit: 10)
    assert {:error, %Error{type: :forbidden}} = Wardrik.deployment_audit(session())
  end

  describe "tokens" do
    test "are made, listed and revoked through the host's module, and recorded" do
      {:ok, grant} = Grant.new(Prefix.parse!("test/"), [:read])
      ana = Principal.new(:user, "ana")

      assert {:ok, %Token{id: id, secret: "secret-" <> id} = made} =
               Wardrik.tokens_create(root(), "ci", grant, for: ana)

      refute inspect(made) =~ "secret-"
      assert [{"token.created", %{"id" => "jon"}}] = Audit.about("tokens/" <> id)

      assert {:ok, tokens} = Wardrik.tokens_list(root())
      assert Enum.any?(tokens, &(&1.id == id))

      assert {:ok, %Token{id: ^id, secret: nil}} = Wardrik.tokens_revoke(root(), id)
      assert [_created, {"token.revoked", _actor}] = Audit.about("tokens/" <> id)
      assert {:error, %Error{type: :not_found}} = Wardrik.tokens_revoke(root(), id)

      assert {:error, %Error{type: :invalid, message: "No token is named refused."}} =
               Wardrik.tokens_create(root(), "refused", grant)

      assert {:error, %Error{type: :forbidden}} = Wardrik.tokens_create(session(), "ci", grant)
      assert {:error, %Error{type: :forbidden}} = Wardrik.tokens_list(session())
    end

    test "for a person reach their own agents, or what names nobody's, never another's" do
      ana = Principal.new(:user, "ana")

      for scope <- ["test/@ana/", "test/@ana/triage", "test/", ""] do
        {:ok, grant} = Grant.new(Prefix.parse!(scope), [:read])
        assert {:ok, %Token{}} = Wardrik.tokens_create(root(), "ok", grant, for: ana)
      end

      {:ok, grant} = Grant.new(Prefix.parse!("test/@jon/"), [:read])

      assert {:error, %Error{type: :invalid, message: message}} =
               Wardrik.tokens_create(root(), "theirs", grant, for: ana)

      assert message == "A token for ana cannot reach test/@jon/, which is jon's."
    end

    test "are unsupported where the host makes none" do
      {:ok, grant} = Grant.new(Prefix.parse!("test/"), [:read])
      none = root(Host.new())

      assert {:error, %Error{type: :unsupported}} = Wardrik.tokens_create(none, "ci", grant)
      assert {:error, %Error{type: :unsupported}} = Wardrik.tokens_list(none)
      assert {:error, %Error{type: :unsupported}} = Wardrik.tokens_revoke(none, "x")
    end
  end
end
