defmodule Wardrik.Store.DurableTest do
  use ExUnit.Case, async: true
  use Wardrik.Store.DurableConformance

  alias Wardrik.Store.Counter

  @moduletag :capture_log

  setup_all do
    store = Wardrik.Store.ETS.new(name: __MODULE__)
    start_supervised!({Wardrik.Store, store})
    %{store: store}
  end

  test "keeps a server across a restart", %{store: store} do
    supervisor = [name: __MODULE__.Servers, prefix: "counters/", backend: {Durable, store: store}]
    child = {Counter, key: "counter", initial_state: %{count: 0}}

    start_supervised!({DurableServer.Supervisor, supervisor}, id: :servers)
    {:ok, {pid, _meta}} = DurableServer.Supervisor.start_child(__MODULE__.Servers, child)
    assert GenServer.call(pid, :increment) == 1

    stop_supervised!(:servers)
    start_supervised!({DurableServer.Supervisor, supervisor}, id: :servers)
    {:ok, {pid, _meta}} = DurableServer.Supervisor.start_child(__MODULE__.Servers, child)

    assert GenServer.call(pid, :count) == 1
  end
end
