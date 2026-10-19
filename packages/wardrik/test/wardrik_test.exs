defmodule WardrikTest do
  use ExUnit.Case, async: true
  use Mimic

  defmodule Search do
    @moduledoc false
    use Wardrik.Tool

    @impl Wardrik.Tool
    def tool,
      do:
        Wardrik.Tool.new!(
          name: "search",
          description: "Searches.",
          run: fn input, _context -> {:ok, input} end
        )
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
    test "is the context its fields name, which names no tools of its own" do
      assert %WardrikDefinition.Context{org: "acme", policies: %{}} = Wardrik.context(org: "acme")
      assert_raise KeyError, fn -> Wardrik.context(servers: []) end
      assert_raise KeyError, fn -> Wardrik.context(tools: [Search]) end
    end
  end

  describe "new/1" do
    test "needs a store" do
      assert_raise KeyError, fn -> Wardrik.new([]) end
    end

    test "keeps definitions and agents' files in the store" do
      store = store()
      host = Wardrik.new(store: store)

      assert %Wardrik.Definitions{store: ^store} = Wardrik.Host.definitions(host)
      assert %WardrikWorkspace.Backend.Store{store: ^store} = Wardrik.Host.workspace(host)
    end

    test "reads each definition against :context, context([]) by default" do
      offered = fn host -> Wardrik.Host.definitions(host).contexts end

      assert offered.(Wardrik.new(store: store())) == Wardrik.context([])

      context = Wardrik.context(org: "acme")
      assert offered.(Wardrik.new(store: store(), context: context)) == context

      by_org = %Wardrik.ByOrg{contexts: %{"acme" => context}}
      assert offered.(Wardrik.new(store: store(), context: by_org)) == by_org
    end

    test "offers the seams it is given, and the None of each it is not" do
      host = Wardrik.new(store: store(), issuer: %Wardrik.OrgIssuer{org: "acme"})

      assert %Wardrik.OrgIssuer{org: "acme"} = Wardrik.Host.issuer(host)
      assert %Wardrik.Credentials.None{} = Wardrik.Host.credentials(host)
      assert Wardrik.Host.expires(host, :api) == 90 * 86_400

      brief = Wardrik.new(store: store(), expires: [api: 3_600])
      assert Wardrik.Host.expires(brief, :api) == 3_600
      assert Wardrik.Host.expires(brief, :session) == 12 * 3_600
    end

    test "holds the tools it is given by name, an agent's operations as sources, and its runtimes" do
      host = Wardrik.new(store: store(), tools: [Search], runtimes: Wardrik.Test.runtimes())

      assert Wardrik.Host.tools(host) == %{"search" => Search}

      assert Wardrik.Host.sources(host) == %{
               "self" => Wardrik.Catalog.Self,
               "agents" => Wardrik.Catalog.Agents
             }

      assert Wardrik.Host.runtimes(host) == Wardrik.Test.runtimes()
      assert Wardrik.Host.runtimes(Wardrik.new(store: store())) == [%Wardrik.LLM.Runtime{}]
    end

    test "makes the scope a principal acts in with the token its issuer issues them" do
      wardrik = Wardrik.new(store: store(), issuer: %Wardrik.OrgIssuer{org: "acme"})
      maria = Wardrik.Principal.new(:user, "maria")

      assert %Wardrik.Scope{token: %Wardrik.Token{principal: ^maria} = token} =
               Wardrik.as(wardrik, maria)

      assert Wardrik.Token.authorize(token, "agent.define", Wardrik.AgentID.parse!("acme/x")) ==
               :ok
    end

    test "issues every token to expire after the host's session length" do
      maria = Wardrik.Principal.new(:user, "maria")
      wardrik = Wardrik.new(store: store(), issuer: %Wardrik.OrgIssuer{org: "acme"})
      brief = Wardrik.new(store: store(), expires: [session: 60])

      assert_in_delta DateTime.diff(Wardrik.as(wardrik, maria).token.expires, DateTime.utc_now()),
                      12 * 3_600,
                      5

      assert_in_delta DateTime.diff(Wardrik.as(brief, maria).token.expires, DateTime.utc_now()),
                      60,
                      5
    end

    test "takes no option it does not know" do
      assert_raise ArgumentError, fn ->
        Wardrik.new(store: store(), workspace: nil)
      end
    end
  end

  test "starts core, the meters, the triggers, then the host's children, each after the one before" do
    host = Wardrik.Host.child(Wardrik.new(store: store()), {Agent, name: :index})

    assert {:ok, {%{strategy: :rest_for_one}, specs}} = Wardrik.init(host)

    assert Enum.map(specs, & &1.id) == [
             Wardrik.Core,
             WardrikPolicy.Supervisor,
             WardrikTrigger.Triggers,
             Agent
           ]

    assert %{start: {Wardrik.Core, :start_link, [[host: ^host]]}} = hd(specs)
    assert %{start: {Agent, :start_link, [[host: ^host, name: :index]]}} = List.last(specs)
  end

  test "makes and drops the store's table in Postgres, as WardrikEcto does" do
    expect(WardrikEcto.Migration, :up, fn [version: 1] -> :ok end)
    expect(WardrikEcto.Migration, :down, fn [version: 1] -> :ok end)

    assert Wardrik.Migration.up(version: 1) == :ok
    assert Wardrik.Migration.down(version: 1) == :ok
  end
end
