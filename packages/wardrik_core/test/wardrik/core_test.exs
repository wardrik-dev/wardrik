defmodule Wardrik.CoreTest do
  use ExUnit.Case, async: false

  test "the harness starts the store, the test model's script, then core, and the fleet under it" do
    ids =
      for {id, _pid, _type, _modules} <- Supervisor.which_children(Wardrik.Test.Supervisor),
          do: id

    assert Enum.reverse(ids) == [WardrikStore, Wardrik.Test.LLM, Wardrik.Core]

    ids = for {id, _pid, _type, _modules} <- Supervisor.which_children(Wardrik.Core), do: id

    assert Wardrik.Fleet.Supervisor in ids
  end

  test "what connects this node to others starts before the fleet" do
    cluster = {Agent, fn -> :connected end}

    {:ok, {_flags, specs}} = Wardrik.Core.init(cluster: [cluster], host: Wardrik.Test.host())
    ids = Enum.map(specs, & &1.id)

    assert Enum.find_index(ids, &(&1 == Agent)) <
             Enum.find_index(ids, &(&1 == Wardrik.Fleet.Supervisor))
  end

  test "a child that restarts restarts the fleet, which comes after every other" do
    {:ok, {flags, specs}} = Wardrik.Core.init(host: Wardrik.Test.host())

    assert flags.strategy == :rest_for_one
    assert List.last(specs).id == Wardrik.Fleet.Supervisor
  end

  test "the audit log is kept in the host's store, and the fleet starts with the host" do
    store = WardrikStore.new(adapter: WardrikStore.Memory, name: :wardrik_test_store)
    host = Wardrik.Host.new(store: store, definitions: %Wardrik.Test.Definitions{})

    {:ok, {_flags, specs}} = Wardrik.Core.init(fleet: [log: true], host: host)

    assert %{start: {Wardrik.Audit, :start_link, [[store: ^store, name: Wardrik.Audit]]}} =
             Enum.find(specs, &(&1.id == Wardrik.Audit))

    assert %{start: {Wardrik.Fleet.Supervisor, :start_link, [opts]}} =
             Enum.find(specs, &(&1.id == Wardrik.Fleet.Supervisor))

    assert Enum.sort(opts) == Enum.sort(log: true, host: host)
  end

  test "needs a host" do
    assert_raise KeyError, fn -> Wardrik.Core.init([]) end
  end

  test "has loaded the modules whose structs the store reads back" do
    for module <- [Wardrik.Agent.State, WardrikStore.Memory, Wardrik.Conversation.Assistant],
        do: assert({:file, _path} = :code.is_loaded(module))
  end
end
