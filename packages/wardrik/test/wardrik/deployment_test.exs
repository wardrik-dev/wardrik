defmodule Wardrik.DeploymentTest do
  # The audit is one for the node, which these tests read.
  use ExUnit.Case, async: false

  import Wardrik.Test, only: [store: 0]

  alias Wardrik.Deployment.Nodes
  alias Wardrik.Error
  alias Wardrik.Event.Log.Entry
  alias Wardrik.Host
  alias Wardrik.Principal
  alias Wardrik.Resource
  alias Wardrik.Role
  alias Wardrik.Scope
  alias Wardrik.Test.Audit
  alias Wardrik.Test.Fleet
  alias Wardrik.Token

  # Read again by telling the test that asked.
  defmodule Reloads do
    @moduledoc false
    defstruct []
  end

  defimpl WardrikDefinition.Contexts, for: Reloads do
    def context(_reloads, _owner), do: %WardrikDefinition.Context{}

    def reload(_reloads, _opts) do
      send(:persistent_term.get({Reloads, :test}), :reloaded)
      [{"agents/broken.md", {:error, "agents/broken.md: tools is a list"}}]
    end
  end

  # Keeps its tokens in the store, each with the secret "secret-" and its id.
  defmodule Tokens do
    @moduledoc false
    defstruct []

    @ns :deployment_test_tokens
    def create(_tokens, "refused", _opts), do: {:error, "No token is named refused."}

    def create(_tokens, name, token: token) do
      id = Wardrik.UUID.v7()

      entry = %Wardrik.Tokens.Entry{
        id: id,
        name: name,
        token: token,
        created_at: DateTime.utc_now()
      }

      {:ok, _vsn} = WardrikStore.put(store(), @ns, id, entry)
      {:ok, %{entry | secret: "secret-" <> id}}
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

  defp host,
    do:
      Wardrik.Test.host(
        definitions: %Wardrik.Definitions{store: store(), contexts: %Reloads{}},
        tokens: %Tokens{}
      )

  defp root(host \\ host()),
    do: Scope.new(host, Token.root(Principal.new("acme/@jon", name: "Jon")))

  # A scope over the agents of one org, which the deployment is not.
  defp scope do
    token = %Token{
      principal: Principal.new("acme/@jon", name: "Jon"),
      scope: [Role.bind([:owner], [Resource.parse!("test/*")])]
    }

    Scope.new(host(), token)
  end

  describe "reloading" do
    test "reads every definition again on this node, says what does not read, and records it" do
      :persistent_term.put({Reloads, :test}, self())

      assert {:ok, %{failed: failed}} = Wardrik.deployment_reload(root())
      assert "agents/broken.md: tools is a list" in failed

      assert_received :reloaded

      assert Enum.any?(
               Audit.about("agents"),
               &match?({"agents.reloaded", %{"id" => "acme/@jon"}}, &1)
             )

      assert {:error, %Error{type: :forbidden}} = Wardrik.deployment_reload(scope())
    end

    test "reads again only the agents the patterns cover, saying still what does not read" do
      :persistent_term.put({Reloads, :test}, self())
      nobody = Resource.parse!("nobody-#{System.unique_integer([:positive])}/*")

      assert {:ok, %{reloaded: [], failed: ["agents/broken.md: tools is a list"]}} =
               Wardrik.deployment_reload(root(), resources: [nobody])

      assert {:error, %Error{type: :forbidden}} =
               Wardrik.deployment_reload(scope(), resources: [nobody])

      assert_raise NimbleOptions.ValidationError, fn ->
        Wardrik.deployment_reload(root(), resources: ["acme/*"])
      end
    end
  end

  test "the nodes count the agents running on each, and those asleep" do
    {_id, _agent} = Fleet.start_agent()

    assert {:ok, %Nodes{nodes: [{node, agents}], asleep: asleep}} =
             Wardrik.deployment_nodes(root())

    assert node == node()
    assert agents >= 1
    assert is_integer(asleep)
    assert {:error, %Error{type: :forbidden}} = Wardrik.deployment_nodes(scope())
  end

  test "the audit reads a page of the changes after a sequence number" do
    :ok = Wardrik.Audit.record(Wardrik.Audit, {:agents_reloaded, [node()]}, by: nil)
    [%{"sequence" => last} | _rest] = Enum.reverse(Audit.all())
    last = String.to_integer(last)

    assert {:ok, [%Entry{sequence: ^last, event: %{"type" => "wardrik.agents.reloaded"}}]} =
             Wardrik.deployment_audit(root(), after: last - 1, limit: 1)

    assert {:ok, []} = Wardrik.deployment_audit(root(), after: last, limit: 10)
    assert {:error, %Error{type: :forbidden}} = Wardrik.deployment_audit(scope())
  end

  describe "tokens" do
    defp reader, do: [Role.bind([:reader], [Resource.parse!("test/agent/*")])]

    test "are made, listed and revoked through the host's module, and recorded" do
      assert {:ok, %Wardrik.Tokens.Entry{id: id, secret: "secret-" <> id} = made} =
               Wardrik.tokens_create(root(), "ci", reader())

      refute inspect(made) =~ "secret-"
      assert [{"token.created", %{"id" => "acme/@jon"}}] = Audit.about("deployment/token/" <> id)

      assert {:ok, tokens} = Wardrik.tokens_list(root())
      assert Enum.any?(tokens, &(&1.id == id))

      assert {:ok, %Wardrik.Tokens.Entry{id: ^id, secret: nil}} =
               Wardrik.tokens_revoke(root(), id)

      assert [_created, {"token.revoked", _actor}] = Audit.about("deployment/token/" <> id)
      assert {:error, %Error{type: :not_found}} = Wardrik.tokens_revoke(root(), id)

      assert {:error, %Error{type: :invalid, message: "No token is named refused."}} =
               Wardrik.tokens_create(root(), "refused", reader())

      assert {:error, %Error{type: :forbidden}} = Wardrik.tokens_create(scope(), "ci", reader())
      assert {:error, %Error{type: :forbidden}} = Wardrik.tokens_list(scope())
    end

    test "act for whoever made them, under the policy they name or the maker's, until they expire" do
      jon = root()
      maker = %{jon | token: %{jon.token | policy: "careful"}}

      assert {:ok, %Wardrik.Tokens.Entry{token: token}} =
               Wardrik.tokens_create(maker, "ci", reader(), policy: "strict")

      assert token.principal == jon.token.principal
      assert token.scope == reader()
      assert token.policy == "strict"

      assert {:ok, %Wardrik.Tokens.Entry{token: %{policy: "careful"}}} =
               Wardrik.tokens_create(maker, "same", reader())

      assert_in_delta DateTime.diff(token.expires, DateTime.utc_now()), 90 * 86_400, 5

      assert {:ok, %Wardrik.Tokens.Entry{token: brief}} =
               Wardrik.tokens_create(jon, "brief", reader(), expires_in: 60)

      assert_in_delta DateTime.diff(brief.expires, DateTime.utc_now()), 60, 5

      shorter = root(Wardrik.Test.host(tokens: %Tokens{}, expires: [api: 3_600]))

      assert {:ok, %Wardrik.Tokens.Entry{token: hour}} =
               Wardrik.tokens_create(shorter, "hour", reader())

      assert_in_delta DateTime.diff(hour.expires, DateTime.utc_now()), 3_600, 5
    end

    test "are unsupported where the host makes none" do
      none = root(Host.new())

      assert {:error, %Error{type: :unsupported}} = Wardrik.tokens_create(none, "ci", reader())
      assert {:error, %Error{type: :unsupported}} = Wardrik.tokens_list(none)
      assert {:error, %Error{type: :unsupported}} = Wardrik.tokens_revoke(none, "x")
    end
  end
end
