defmodule Wardrik.NotifyStandbyTest do
  use ExUnit.Case, async: false

  alias Wardrik.Test.FailingStore
  alias Wardrik.Test.Peer

  setup %{test: test} do
    store = FailingStore.new(:"store #{test}")
    start_supervised!({WardrikStore, store})

    wardrik =
      Wardrik.new(
        authorizer: {Wardrik.Test.Allow, []},
        resolver: {Wardrik.Test.Owned, :"wardrik #{test}"},
        name: :"wardrik #{test}",
        store: store
      )

    :ok = Peer.watch(node())
    on_exit(fn -> :telemetry.detach({Peer, self()}) end)
    %{store: store, wardrik: wardrik}
  end

  test "starts the notifier again when it stops", %{wardrik: wardrik} do
    start_supervised!({Wardrik, wardrik})
    assert_receive {:notifier_started, _node}

    {pid, _meta} =
      DurableServer.Supervisor.lookup(Module.concat(wardrik.name, Wardrik.Notify), "notifier")

    Process.exit(pid, :kill)

    assert_receive {:notifier_started, _node}, 5_000
  end

  test "starts the notifier once the store takes its lock", %{store: store, wardrik: wardrik} do
    FailingStore.fail_path(store, "wardrik/durable:notify/notifier")
    start_supervised!({Wardrik, wardrik})
    refute_received {:notifier_started, _node}

    FailingStore.recover(store)

    assert_receive {:notifier_started, _node}, 5_000
  end
end
