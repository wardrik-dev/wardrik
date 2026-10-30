defmodule Wardrik.StoreFailuresTest do
  use ExUnit.Case, async: false

  import Wardrik.Test.Wardrik

  alias Wardrik.Test.FailingStore

  @model "anthropic:claude-haiku-4-5"
  @trigger %{"name" => "daily", "every" => "1d", "prompt" => "Go."}

  setup context do
    store = FailingStore.new(:"store #{context.test}")
    wardrik = Wardrik.new(name: :"wardrik #{context.test}", store: store)
    start_supervised!({WardrikStore, store})
    start_supervised!({Wardrik, wardrik})
    %{store: store, scope: owner(wardrik)}
  end

  defp define(scope, triggers),
    do:
      Wardrik.run(scope, "agent.define", %{
        "agent" => "acme/digest",
        "model" => @model,
        "triggers" => triggers
      })

  test "a definition whose triggers the store can't keep is unavailable", %{
    store: store,
    scope: scope
  } do
    FailingStore.fail(store, "wardrik_triggers")

    assert {:error, %Wardrik.Error{type: :unavailable, message: message}} =
             define(scope, [@trigger])

    assert message =~ "acme/digest wasn't saved"
  end

  test "a trigger the store can't remove is unavailable", %{store: store, scope: scope} do
    assert {:ok, _agent} = define(scope, [@trigger])
    FailingStore.fail(store, "wardrik_triggers")

    assert {:error, %Wardrik.Error{type: :unavailable}} =
             Wardrik.run(scope, "agent.trigger_remove", %{
               "agent" => "acme/digest",
               "trigger" => "daily"
             })
  end
end
