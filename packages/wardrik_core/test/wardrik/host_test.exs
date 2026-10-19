defmodule Wardrik.HostTest do
  use ExUnit.Case, async: true

  alias Wardrik.Host
  alias Wardrik.Principal

  import Wardrik.AgentID, only: [sigil_A: 2]

  defmodule Issued do
    @moduledoc false
    defstruct []
  end

  defimpl Wardrik.Issuer, for: Issued do
    def issue(_issuer, principal, _opts), do: Wardrik.Token.root(principal)
  end

  test "offers each seam it names, and the None of each it leaves out" do
    host = Host.new(issuer: %Issued{}, tokens: %Wardrik.Tokens.None{})

    assert Host.issuer(host) == %Issued{}
    assert Host.definitions(host) == %Wardrik.Specs.None{}
    assert Host.connections(host) == %Wardrik.Connections.None{}
    assert Host.credentials(host) == %Wardrik.Credentials.None{}
    assert Host.tokens(host) == %Wardrik.Tokens.None{}
    assert Host.triggers(host) == %Wardrik.Triggers.None{}
    assert Host.store(host) == WardrikStore.new(adapter: WardrikStore.None)
    assert_raise ArgumentError, fn -> Host.new(ledger: %Issued{}) end
  end

  test "lasts each kind of token as :expires says, and the others as by default" do
    assert Host.expires(Host.new(), :api) == 90 * 86_400
    assert Host.expires(Host.new(), :session) == 12 * 3_600

    brief = Host.new(expires: [api: 60])
    assert Host.expires(brief, :api) == 60
    assert Host.expires(brief, :session) == 12 * 3_600
    assert Host.expires(Host.new(expires: [session: 60]), :session) == 60

    assert_raise ArgumentError, fn -> Host.new(expires: [forever: 60]) end
  end

  test "finds each runtime it runs by its key, and raises on one it does not run" do
    host = Host.new(runtimes: Wardrik.Test.runtimes())

    assert Host.runtime(host, "test") == %Wardrik.Test.Runtime{}
    assert Host.runtime(Host.new(), "model") == %Wardrik.LLM.Runtime{}
    assert_raise ArgumentError, ~r/no runtime "test"/, fn -> Host.runtime(Host.new(), "test") end

    assert {:error, _why} =
             Wardrik.Runtime.read(%Wardrik.Test.Runtime{}, %{}, %Wardrik.Runtime.Context{})
  end

  test "holds what packages add in the order they add it, and refuses a name taken" do
    host =
      Host.new()
      |> Host.register(:tools, [{"search", MyApp.Search}])
      |> Host.register(:sources, [{"workers", MyApp.Workers}])
      |> Host.register(:routes, [{["v1", "hooks"], {MyApp.Hooks, []}}])
      |> Host.register(:runtimes, [%Wardrik.Test.Runtime{}])
      |> Host.child({MyApp.Index, name: :a})
      |> Host.child({MyApp.Index, name: :b})

    assert Host.tools(host) == %{"search" => MyApp.Search}
    assert Host.sources(host) == %{"workers" => MyApp.Workers}
    assert Host.routes(host) == [{["v1", "hooks"], {MyApp.Hooks, []}}]
    assert Host.runtimes(host) == Wardrik.Test.runtimes()
    assert Host.children(host) == [{MyApp.Index, name: :a}, {MyApp.Index, name: :b}]

    assert_raise ArgumentError, ~r/tools has "search" already/, fn ->
      Host.register(host, :tools, [{"search", MyApp.Other}])
    end

    assert_raise ArgumentError, ~r/runtimes has "model" already/, fn ->
      Host.register(host, :runtimes, [%Wardrik.LLM.Runtime{}])
    end

    assert_raise ArgumentError, fn ->
      Host.register(Host.new(), :sources, [{"a", MyApp.A}, {"a", MyApp.B}])
    end
  end

  test "each None answers that the host offers nothing" do
    id = ~A"acme/triage"
    host = Host.new()
    connections = Host.connections(host)
    tokens = Host.tokens(host)
    definitions = Host.definitions(host)

    assert Wardrik.Connections.list(connections, "acme") == :unsupported
    assert Wardrik.Connections.connect(connections, "github", "acme", nil) == :unsupported
    assert Wardrik.Connections.disconnect(connections, "github", "acme") == :unsupported
    assert Wardrik.Tokens.create(tokens, "t", token: nil) == :unsupported
    assert Wardrik.Tokens.list(tokens) == :unsupported
    assert Wardrik.Tokens.revoke(tokens, "t1") == :unsupported

    assert Wardrik.Triggers.deliver(Host.triggers(host), id, "issues", %{headers: [], body: ""}) ==
             :unsupported

    assert Wardrik.Issuer.issue(Host.issuer(host), Principal.new("acme/@maria"), []).scope == []
    assert Wardrik.Credentials.key(Host.credentials(host), "ANTHROPIC_API_KEY") == :error

    assert Wardrik.Credentials.resolve(Host.credentials(host), "github", nil) ==
             {:error, :no_resolver}

    assert Wardrik.Credentials.refused(Host.credentials(host), "github", nil) == :ok
    assert Wardrik.Specs.current(definitions, id, host: host) == :none
    assert Wardrik.Specs.defined(definitions, Wardrik.Resource.parse!("*")) == []
  end
end
