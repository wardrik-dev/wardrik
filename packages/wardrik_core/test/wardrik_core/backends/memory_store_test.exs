defmodule WardrikCore.Backends.MemoryStoreTest do
  use ExUnit.Case, async: true

  alias WardrikCore.Backends.MemoryStore

  setup do
    store = :"memory_store_#{System.unique_integer([:positive])}"
    start_supervised!({MemoryStore, name: store})
    %{store: store}
  end

  test "writes only over the version it was given", %{store: store} do
    {:ok, %{etag: first}} = MemoryStore.put_object(store, "a", 1, [])
    {:ok, %{etag: second}} = MemoryStore.put_object(store, "a", 2, etag: first)

    assert {:error, :conflict} = MemoryStore.put_object(store, "a", 3, etag: first)
    assert {:ok, %{body: 2, etag: ^second}} = MemoryStore.get_object(store, "a", [])
  end

  test "claims a key once", %{store: store} do
    assert {:ok, {:claimed, _etag}} = MemoryStore.try_claim(store, "a", 1)
    assert {:error, :already_claimed} = MemoryStore.try_claim(store, "a", 2)
  end

  test "deletes only the version it was given", %{store: store} do
    {:ok, %{etag: first}} = MemoryStore.put_object(store, "a", 1, [])
    {:ok, _object} = MemoryStore.put_object(store, "a", 2, [])

    assert {:error, :conflict} = MemoryStore.delete_object(store, "a", etag: first)
    assert :ok = MemoryStore.delete_object(store, "a")
    assert {:error, :not_found} = MemoryStore.delete_object(store, "a")
    assert {:error, :not_found} = MemoryStore.get_object(store, "a", [])
  end

  test "updates what's there", %{store: store} do
    {:ok, _object} = MemoryStore.put_object(store, "a", 1, [])

    assert {:ok, %{body: 2}} =
             MemoryStore.update_object(store, "a", fn %{body: n} -> {:ok, n + 1} end, [])

    assert {:error, :not_found} = MemoryStore.update_object(store, "b", &{:ok, &1}, [])
  end

  test "lists the keys under a prefix", %{store: store} do
    {:ok, _object} = MemoryStore.put_object(store, "agents/a", 1, [])
    {:ok, _object} = MemoryStore.put_object(store, "other/b", 2, [])

    assert [%{key: "agents/a"} = listed] =
             MemoryStore.list_all_objects_stream(store, "agents/", [])

    refute Map.has_key?(listed, :body)

    assert [%{key: "agents/a", body: 1}] =
             MemoryStore.list_all_objects_stream(store, "agents/", include_objects: true)
  end

  test "is ready once started", %{store: store} do
    assert :ok = MemoryStore.ensure_ready(store)
    assert {:error, :not_started} = MemoryStore.ensure_ready(:never_started)
  end
end
