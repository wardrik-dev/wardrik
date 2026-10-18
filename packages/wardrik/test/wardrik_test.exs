defmodule WardrikTest do
  use ExUnit.Case, async: true
  use Mimic

  defmodule Search do
    @moduledoc false
  end

  defp data_dir, do: Path.join(System.tmp_dir!(), "wardrik-#{System.unique_integer([:positive])}")

  defp store, do: Wardrik.store(data_dir: data_dir())

  describe "store/1" do
    test "is the store its settings name" do
      assert %WardrikStore.EKV{} = store()

      assert %WardrikEcto.Store{repo: MyApp.Repo, discovery_interval_ms: 50} =
               Wardrik.store(repo: MyApp.Repo, discovery_interval_ms: 50)

      bucket = [
        bucket: "wardrik",
        endpoint: "http://127.0.0.1:59000",
        region: "auto",
        access_key_id: "id",
        secret_access_key: "secret"
      ]

      assert %WardrikS3.Store{bucket: "wardrik"} = Wardrik.store(bucket)
    end

    test "names one store" do
      assert_raise ArgumentError, ~r/names one store/, fn -> Wardrik.store([]) end

      assert_raise ArgumentError, ~r/names one store/, fn ->
        Wardrik.store(repo: MyApp.Repo, data_dir: data_dir())
      end
    end
  end

  describe "context/1" do
    test "offers what its fields name, and an agent's operations unless they name sources" do
      assert %WardrikDefinition.Context{
               tools: [],
               sources: [self: Wardrik.Catalog.Self, agents: Wardrik.Catalog.Agents]
             } = Wardrik.context([])

      assert %WardrikDefinition.Context{tools: [Search], sources: [self: Wardrik.Catalog.Self]} =
               Wardrik.context(tools: [Search], sources: [self: Wardrik.Catalog.Self])
    end
  end

  describe "new/1" do
    test "needs a store" do
      assert_raise KeyError, fn -> Wardrik.new([]) end
    end

    test "keeps definitions and agents' files in the store" do
      store = store()
      host = Wardrik.host(Wardrik.new(store: store))

      assert %WardrikDefinition.Kept{store: ^store} = Wardrik.Host.definitions(host)
      assert %WardrikWorkspace.Backend.Store{store: ^store} = Wardrik.Host.workspace(host)
    end

    test "reads each definition against :context, context([]) by default" do
      offered = fn wardrik -> Wardrik.Host.definitions(Wardrik.host(wardrik)).contexts end

      assert offered.(Wardrik.new(store: store())) == Wardrik.context([])

      context = Wardrik.context(tools: [Search])
      assert offered.(Wardrik.new(store: store(), context: context)) == context

      by_org = %Wardrik.ByOrg{contexts: %{"acme" => context}}
      assert offered.(Wardrik.new(store: store(), context: by_org)) == by_org
    end

    test "offers the seams it is given, and the None of each it is not" do
      wardrik =
        Wardrik.new(store: store(), issuer: %Wardrik.OrgIssuer{org: "acme"})

      assert %Wardrik.OrgIssuer{org: "acme"} = Wardrik.Host.issuer(Wardrik.host(wardrik))
      assert %Wardrik.Credentials.None{} = Wardrik.Host.credentials(Wardrik.host(wardrik))
      assert Wardrik.Host.expires(Wardrik.host(wardrik), :api) == 90 * 86_400

      brief = Wardrik.new(store: store(), expires: [api: 3_600])
      assert Wardrik.Host.expires(Wardrik.host(brief), :api) == 3_600
    end

    test "makes the scope a principal acts in with the token its issuer issues them" do
      wardrik = Wardrik.new(store: store(), issuer: %Wardrik.OrgIssuer{org: "acme"})
      maria = Wardrik.Principal.new(:user, "maria")

      assert %Wardrik.Scope{token: %Wardrik.Token{principal: ^maria} = token} =
               Wardrik.as(wardrik, maria)

      assert Wardrik.as(Wardrik.host(wardrik), maria).token == token

      assert Wardrik.Token.authorize(token, "agent.define", Wardrik.AgentID.parse!("acme/x")) ==
               :ok
    end

    test "takes no option it does not know" do
      assert_raise ArgumentError, fn ->
        Wardrik.new(store: store(), workspace: nil)
      end
    end
  end

  test "starts the store, core, the meters and the triggers, each after the one before" do
    wardrik = Wardrik.new(store: store(), fleet: [log: false])

    assert {:ok, {%{strategy: :rest_for_one}, specs}} = Wardrik.init(wardrik)

    assert Enum.map(specs, & &1.id) == [
             WardrikStore,
             Wardrik.Core,
             WardrikPolicy.Supervisor,
             WardrikTrigger.Triggers
           ]

    assert %{start: {Wardrik.Core, :start_link, [opts]}} = Enum.at(specs, 1)
    assert opts[:fleet] == [log: false]
    assert opts[:host] == Wardrik.host(wardrik)
  end

  test "makes and drops the store's table in Postgres, as WardrikEcto does" do
    expect(WardrikEcto.Migration, :up, fn [version: 1] -> :ok end)
    expect(WardrikEcto.Migration, :down, fn [version: 1] -> :ok end)

    assert Wardrik.Migration.up(version: 1) == :ok
    assert Wardrik.Migration.down(version: 1) == :ok
  end
end
