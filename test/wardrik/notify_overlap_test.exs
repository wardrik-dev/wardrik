defmodule Wardrik.NotifyOverlapTest do
  # Two peers that share a store but aren't clustered, as the old and new releases of a
  # blue-green deploy share a database for the moments both run.
  use ExUnit.Case, async: false

  alias Wardrik.Test.Peer

  @moduletag :peer

  setup %{test: test} do
    store = :"store #{System.unique_integer([:positive])}"
    start_supervised!({WardrikStore, WardrikStore.ETS.new(name: store)}, id: test)
    %{store: store}
  end

  test "starts beside a node that runs the notifier on the same store", %{store: store} do
    old = Peer.start(:old)
    assert {:ok, _supervisor} = Peer.wardrik(old, store)
    assert Peer.notifier?(old)

    new = Peer.start(:new)
    assert {:ok, _supervisor} = Peer.wardrik(new, store)

    assert Peer.notifier?(old)
    refute Peer.notifier?(new)
  end

  test "takes the notifier over once the node that ran it stops", %{store: store} do
    old = Peer.start(:old)
    {:ok, running} = Peer.wardrik(old, store)

    new = Peer.start(:new)
    :ok = Peer.watch(new)
    assert {:ok, _supervisor} = Peer.wardrik(new, store)

    :ok = Peer.stop(old, running)

    # A release that stops on purpose hands the notifier over at once, not when its lease ends.
    assert_receive {:notifier_started, ^new}, 5_000
  end
end
