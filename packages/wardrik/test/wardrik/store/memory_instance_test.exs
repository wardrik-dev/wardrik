defmodule Wardrik.Store.MemoryInstanceTest do
  use ExUnit.Case, async: true

  alias Wardrik.Store.Memory

  setup do
    name = :"memory_#{System.unique_integer([:positive])}"
    start_supervised!({Memory, name: name})
    %{opts: [name: name]}
  end

  test "clear/1 forgets everything", %{opts: opts} do
    {:ok, _vsn} = Memory.put(:clear, "a", 1, opts)
    :ok = Memory.clear(opts)

    assert Memory.get(:clear, "a", opts) == nil
  end

  test "an instance of its own holds what is written to it, and nothing else", %{opts: opts} do
    {:ok, vsn} = Memory.put(:mine, "a", 1, opts)

    assert Memory.lookup(:mine, "a", opts) == {1, vsn}
    assert {:error, :conflict} = Memory.delete(:mine, "a", [if_vsn: vsn + 1] ++ opts)
    assert :ok = Memory.delete(:mine, "a", [if_vsn: vsn] ++ opts)
    assert Memory.lookup(:mine, "a", opts) == nil
  end

  test "lists the keys under a prefix in order, and none past it or in another namespace", %{
    opts: opts
  } do
    for key <- ~w(b/2 a b/1 b c ba), do: {:ok, _vsn} = Memory.put(:listed, key, key, opts)
    {:ok, _vsn} = Memory.put(:other, "b/3", 3, opts)
    {:ok, _vsn} = Memory.put(:zzz, "b/4", 4, opts)

    assert Memory.keys(:listed, "b", opts) == ~w(b b/1 b/2 ba)
    assert Memory.keys(:listed, "b/", opts) == ~w(b/1 b/2)
    assert Memory.keys(:listed, "", opts) == ~w(a b b/1 b/2 ba c)
    assert Memory.keys(:listed, "d", opts) == []
    assert Memory.keys(:nothing, "", opts) == []
  end

  test "is kept in memory, and needs no other node" do
    assert Memory.check([]) == {:ok, "in this node's memory"}
    assert Memory.quorum(3) == 1
  end

  test "holds a one-node fleet through Wardrik.Store.Durable" do
    assert Memory.durable_backend(discovery_interval_ms: 200) ==
             {Wardrik.Store.Durable, store: Memory, discovery_interval_ms: 200}
  end
end
