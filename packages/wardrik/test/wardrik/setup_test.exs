defmodule Wardrik.SetupTest do
  use ExUnit.Case, async: true

  alias Wardrik.Store.ETS

  describe "new/1's oauth" do
    test "resolves apps with Wardrik.OAuth.Apps unless it names a resolver" do
      wardrik =
        Wardrik.new(
          authorizer: {Wardrik.Test.Allow, []},
          resolver: {Wardrik.Test.Owned, MyApp.AgentRuntime},
          name: MyApp.AgentRuntime,
          vault_keys: ["key"],
          oauth: [page: "https://agents.example.com/oauth"]
        )

      refute Keyword.has_key?(wardrik.oauth, :resolver)
      assert wardrik.oauth[:providers] == []
    end

    test "needs the page sign-ins come back to" do
      assert_raise NimbleOptions.ValidationError, ~r/required :page/, fn ->
        Wardrik.new(
          authorizer: {Wardrik.Test.Allow, []},
          resolver: {Wardrik.Test.Owned, MyApp.AgentRuntime},
          name: MyApp.AgentRuntime,
          vault_keys: ["key"],
          oauth: [resolver: {Wardrik.Test.OAuthApps, []}]
        )
      end
    end
  end

  describe "new/1's store" do
    test "is in memory, named after the Wardrik, unless set" do
      wardrik =
        Wardrik.new(
          authorizer: {Wardrik.Test.Allow, []},
          resolver: {Wardrik.Test.Owned, MyApp.AgentRuntime},
          name: MyApp.AgentRuntime
        )

      assert wardrik.store == ETS.new(name: MyApp.AgentRuntime.Store)
      assert wardrik.backend == {Wardrik.Store.Durable, store: wardrik.store}
    end

    test "is built from an adapter and its options" do
      wardrik =
        Wardrik.new(
          authorizer: {Wardrik.Test.Allow, []},
          resolver: {Wardrik.Test.Owned, MyApp.AgentRuntime},
          name: MyApp.AgentRuntime,
          store: {Wardrik.Store.EKV, data_dir: "/tmp/wardrik"}
        )

      assert %Wardrik.Store{adapter: Wardrik.Store.EKV, config: %{name: MyApp.AgentRuntime.Store}} =
               wardrik.store

      assert wardrik.store.config.options[:data_dir] == "/tmp/wardrik"
    end

    test "keeps the name its options give" do
      wardrik =
        Wardrik.new(
          authorizer: {Wardrik.Test.Allow, []},
          resolver: {Wardrik.Test.Owned, MyApp.AgentRuntime},
          name: MyApp.AgentRuntime,
          store: {Wardrik.Store.ETS, name: MyApp.Store}
        )

      assert wardrik.store == ETS.new(name: MyApp.Store)
    end

    test "is used as given when built" do
      store = ETS.new(name: MyApp.Store)

      wardrik =
        Wardrik.new(
          authorizer: {Wardrik.Test.Allow, []},
          resolver: {Wardrik.Test.Owned, MyApp.AgentRuntime},
          name: MyApp.AgentRuntime,
          store: store
        )

      assert wardrik.store == store
      assert wardrik.backend == {Wardrik.Store.Durable, store: store}
    end

    test "says which adapter isn't compiled" do
      assert_raise ArgumentError, ~r/NoSuchStore isn't compiled/, fn ->
        Wardrik.new(
          authorizer: {Wardrik.Test.Allow, []},
          resolver: {Wardrik.Test.Owned, MyApp.AgentRuntime},
          name: MyApp.AgentRuntime,
          store: {NoSuchStore, []}
        )
      end
    end

    test "says how to give a store it can't read" do
      assert_raise NimbleOptions.ValidationError, ~r/:store/, fn ->
        Wardrik.new(
          authorizer: {Wardrik.Test.Allow, []},
          resolver: {Wardrik.Test.Owned, MyApp.AgentRuntime},
          name: MyApp.AgentRuntime,
          store: "postgres://localhost/x"
        )
      end
    end

    test "takes no :data_dir of its own" do
      assert_raise NimbleOptions.ValidationError, ~r/data_dir/, fn ->
        Wardrik.new(
          authorizer: {Wardrik.Test.Allow, []},
          resolver: {Wardrik.Test.Owned, MyApp.AgentRuntime},
          name: MyApp.AgentRuntime,
          data_dir: "/tmp/wardrik"
        )
      end
    end
  end

  describe "new/1's seams" do
    test "are the vault and Wardrik.OAuth unless set, and no key source" do
      wardrik =
        Wardrik.new(
          authorizer: {Wardrik.Test.Allow, []},
          resolver: {Wardrik.Test.Owned, MyApp.AgentRuntime},
          name: MyApp.AgentRuntime,
          vault_keys: ["key"],
          oauth: [
            page: "https://agents.example.com/oauth",
            resolver: {Wardrik.Test.OAuthApps, []}
          ]
        )

      assert wardrik.credentials == {Wardrik.Vault, MyApp.AgentRuntime.Vault}

      assert wardrik.key_source == nil
      assert wardrik.grants == {Wardrik.OAuth, MyApp.AgentRuntime.OAuth}
    end

    test "are none without keys or oauth" do
      wardrik =
        Wardrik.new(
          authorizer: {Wardrik.Test.Allow, []},
          resolver: {Wardrik.Test.Owned, MyApp.AgentRuntime},
          name: MyApp.AgentRuntime
        )

      assert {wardrik.credentials, wardrik.key_source, wardrik.grants} == {nil, nil, nil}
      assert Wardrik.Setup.agent(wardrik, agent_id: "acme/bot")[:credentials] == nil
    end

    test "take the host's own, which every agent gets" do
      wardrik =
        Wardrik.new(
          authorizer: {Wardrik.Test.Allow, []},
          resolver: {Wardrik.Test.Owned, MyApp.AgentRuntime},
          name: MyApp.AgentRuntime,
          credentials: MyApp.Tokens,
          key_source: {MyApp.Keys, region: "eu"},
          grants: {MyApp.Grants, []}
        )

      assert wardrik.grants == {MyApp.Grants, []}

      opts = Wardrik.Setup.agent(wardrik, agent_id: "acme/bot")
      assert opts[:credentials] == MyApp.Tokens
      assert opts[:keys] == {MyApp.Keys, region: "eu"}
    end
  end
end
