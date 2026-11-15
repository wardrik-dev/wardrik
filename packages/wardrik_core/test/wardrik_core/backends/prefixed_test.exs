defmodule WardrikCore.Backends.PrefixedTest do
  use ExUnit.Case, async: true

  alias WardrikCore.Backends.MemoryStore

  test "runs two instances on one node, each keeping agents under the same prefix in its own store" do
    [one, two] =
      for _n <- 1..2 do
        id = System.unique_integer([:positive])
        store = :"prefixed_store_#{id}"
        instance = :"prefixed_#{id}"
        start_supervised!({MemoryStore, name: store}, id: store)

        start_supervised!(
          {WardrikCore, name: instance, backend: {MemoryStore, name: store}},
          id: instance
        )

        %{store: store, instance: instance}
      end

    {:ok, _pid} =
      WardrikCore.start_agent(one.instance, agent_id: "a", model: "anthropic:claude-haiku-4-5")

    assert WardrikCore.list(one.instance) == [{"a", nil}]
    assert WardrikCore.list(two.instance) == []
    assert WardrikCore.saved_key(one.instance, "a") == "wardrik/agents/a"
    assert {:ok, _object} = MemoryStore.get_object(one.store, "wardrik/agents/a", [])
  end
end
