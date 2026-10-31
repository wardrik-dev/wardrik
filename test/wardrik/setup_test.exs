defmodule Wardrik.SetupTest do
  use ExUnit.Case, async: true

  describe "new/1's oauth" do
    test "needs the page sign-ins come back to" do
      assert_raise NimbleOptions.ValidationError, ~r/required :page/, fn ->
        Wardrik.new(name: MyApp.AgentRuntime, keys: ["key"], oauth: [providers: []])
      end
    end
  end

  describe "new/1's store" do
    test "is in memory, named after the Wardrik, unless set" do
      wardrik = Wardrik.new(name: MyApp.AgentRuntime)

      assert wardrik.store == WardrikStore.ETS.new(name: MyApp.AgentRuntime.Store)
      assert wardrik.backend == {WardrikStore.Durable, store: wardrik.store}
    end

    test "is built from an adapter and its options" do
      wardrik =
        Wardrik.new(
          name: MyApp.AgentRuntime,
          store: {WardrikStore.EKV, data_dir: "/tmp/wardrik"}
        )

      assert %WardrikStore{adapter: WardrikStore.EKV, config: %{name: MyApp.AgentRuntime.Store}} =
               wardrik.store

      assert wardrik.store.config.options[:data_dir] == "/tmp/wardrik"
    end

    test "keeps the name its options give" do
      wardrik =
        Wardrik.new(name: MyApp.AgentRuntime, store: {WardrikStore.ETS, name: MyApp.Store})

      assert wardrik.store == WardrikStore.ETS.new(name: MyApp.Store)
    end

    test "is used as given when built" do
      store = WardrikStore.ETS.new(name: MyApp.Store)
      wardrik = Wardrik.new(name: MyApp.AgentRuntime, store: store)

      assert wardrik.store == store
      assert wardrik.backend == {WardrikStore.Durable, store: store}
    end

    test "says which adapter isn't compiled" do
      assert_raise ArgumentError, ~r/NoSuchStore isn't compiled/, fn ->
        Wardrik.new(name: MyApp.AgentRuntime, store: {NoSuchStore, []})
      end
    end

    test "says how to give a store it can't read" do
      assert_raise NimbleOptions.ValidationError, ~r/:store/, fn ->
        Wardrik.new(name: MyApp.AgentRuntime, store: "postgres://localhost/x")
      end
    end

    test "takes no :data_dir of its own" do
      assert_raise NimbleOptions.ValidationError, ~r/data_dir/, fn ->
        Wardrik.new(name: MyApp.AgentRuntime, data_dir: "/tmp/wardrik")
      end
    end
  end

  describe "new/1's seams" do
    test "are the vault, Wardrik.Keys and WardrikOAuth unless set" do
      wardrik =
        Wardrik.new(
          name: MyApp.AgentRuntime,
          keys: ["key"],
          oauth: [page: "https://agents.example.com/oauth"]
        )

      assert wardrik.credentials == {WardrikVault, MyApp.AgentRuntime.Vault}

      assert wardrik.key_source ==
               {Wardrik.Keys, vault: MyApp.AgentRuntime.Vault, deployment: false}

      assert wardrik.grants == {WardrikOAuth, MyApp.AgentRuntime.OAuth}
    end

    test "are none without keys or oauth" do
      wardrik = Wardrik.new(name: MyApp.AgentRuntime)

      assert {wardrik.credentials, wardrik.key_source, wardrik.grants} == {nil, nil, nil}
      assert Wardrik.Setup.agent(wardrik, agent_id: "acme/bot")[:credentials] == nil
    end

    test "take the host's own, which every agent gets" do
      wardrik =
        Wardrik.new(
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

    test "fall back to the deployment's keys only when the host says so" do
      wardrik = Wardrik.new(name: MyApp.AgentRuntime, keys: ["key"], deployment_keys: true)

      assert wardrik.key_source ==
               {Wardrik.Keys, vault: MyApp.AgentRuntime.Vault, deployment: true}
    end
  end
end
