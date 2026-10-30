defmodule Wardrik.SetupTest do
  use ExUnit.Case, async: true

  alias Wardrik.Setup

  describe "wardrik/1's store" do
    test "is in memory, named after the Wardrik, unless set" do
      wardrik = Setup.wardrik(name: MyApp.AgentRuntime)

      assert wardrik.store == WardrikStore.ETS.new(name: MyApp.AgentRuntime.Store)
      assert wardrik.backend == {WardrikStore.Durable, store: wardrik.store}
    end

    test "is built from an adapter and its options" do
      wardrik =
        Setup.wardrik(
          name: MyApp.AgentRuntime,
          store: {WardrikStore.EKV, data_dir: "/tmp/wardrik"}
        )

      assert %WardrikStore{adapter: WardrikStore.EKV, config: %{name: MyApp.AgentRuntime.Store}} =
               wardrik.store

      assert wardrik.store.config.options[:data_dir] == "/tmp/wardrik"
    end

    test "keeps the name its options give" do
      wardrik =
        Setup.wardrik(name: MyApp.AgentRuntime, store: {WardrikStore.ETS, name: MyApp.Store})

      assert wardrik.store == WardrikStore.ETS.new(name: MyApp.Store)
    end

    test "is used as given when built" do
      store = WardrikStore.ETS.new(name: MyApp.Store)
      wardrik = Setup.wardrik(name: MyApp.AgentRuntime, store: store)

      assert wardrik.store == store
      assert wardrik.backend == {WardrikStore.Durable, store: store}
    end

    test "says which adapter isn't compiled" do
      assert_raise ArgumentError, ~r/NoSuchStore isn't compiled/, fn ->
        Setup.wardrik(name: MyApp.AgentRuntime, store: {NoSuchStore, []})
      end
    end

    test "says how to give a store it can't read" do
      assert_raise ArgumentError, ~r/Give Wardrik's :store as \{adapter, opts\}/, fn ->
        Setup.wardrik(name: MyApp.AgentRuntime, store: "postgres://localhost/x")
      end
    end

    test "takes no :data_dir of its own" do
      assert_raise ArgumentError, ~r/data_dir/, fn ->
        Setup.wardrik(name: MyApp.AgentRuntime, data_dir: "/tmp/wardrik")
      end
    end
  end
end
