defmodule WardrikStore.DurableTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias DurableServer.Meta
  alias DurableServer.StoredState
  alias WardrikStore.Adapter.WardrikStore.Memory, as: Impl
  alias WardrikStore.Durable
  alias WardrikStore.Memory

  setup_all do
    store = WardrikStore.new(adapter: Memory, name: :durable_test)
    start_supervised!({WardrikStore, store})
    {:ok, %{state: state} = backend} = Durable.init_backend(store: store)
    %{state: state, backend: backend, store: store}
  end

  test "polls for heartbeats, at the intervals it was given", %{backend: backend} do
    assert backend.defaults == %{
             heartbeat_tracking_mode: :poll,
             discovery_interval_ms: 30_000,
             heartbeat_interval_ms: 10_000,
             heartbeat_reconcile_interval_ms: 10_000
           }

    assert {:ok, %{defaults: %{discovery_interval_ms: 5}}} =
             Durable.init_backend(%{store: backend.state.store, discovery_interval_ms: 5})

    assert Durable.ensure_ready(backend.state) == :ok
  end

  test "writes an object, and over its etag only", %{state: state} do
    key = unique()

    assert {:error, :not_found} = Durable.get_object(state, key, [])

    assert {:ok, %{body: %{"a" => 1}, etag: first}} =
             Durable.put_object(state, key, %{"a" => 1}, [])

    assert {:ok, %{body: %{"a" => 2}, etag: second}} =
             Durable.put_object(state, key, %{"a" => 2}, etag: first)

    assert {:error, :conflict} = Durable.put_object(state, key, %{"a" => 3}, etag: first)
    assert {:error, :conflict} = Durable.put_object(state, key, %{"a" => 3}, etag: "not an etag")

    assert {:error, :conflict} =
             Durable.put_object(state, key, %{"a" => 3}, etag: Base.url_encode64("x"))

    assert {:ok, %{body: %{"a" => 2}, etag: ^second}} =
             Durable.get_object(state, key, consistent: true)
  end

  test "claims a key once", %{state: state} do
    key = unique()

    assert {:ok, {:claimed, _etag}} = Durable.try_claim(state, key, %{"owner" => "a"})
    assert {:error, :already_claimed} = Durable.try_claim(state, key, %{"owner" => "b"})
  end

  test "updates over what it read, again when another writer got there first", %{state: state} do
    key = unique()
    {:ok, _object} = Durable.put_object(state, key, 1, [])

    assert {:ok, %{body: 11}} =
             Durable.update_object(
               state,
               key,
               fn %{body: body} ->
                 if body == 1, do: {:ok, _raced} = Durable.put_object(state, key, 10, [])
                 {:ok, body + 1}
               end,
               []
             )

    assert {:error, :not_found} = Durable.update_object(state, unique(), &{:ok, &1}, [])

    assert {:error, :nope} =
             Durable.update_object(state, key, fn _object -> {:error, :nope} end, timeout: 1_000)

    assert {:error, :max_retries_exceeded} =
             Durable.update_object(
               state,
               key,
               fn %{body: body} ->
                 {:ok, _raced} = Durable.put_object(state, key, body, [])
                 {:ok, body}
               end,
               max_retries: 1
             )
  end

  test "gives up an update that outlasts its timeout", %{state: state} do
    key = unique()
    {:ok, _object} = Durable.put_object(state, key, 1, [])

    never = fn _object -> receive(do: (:never -> {:ok, 2})) end
    assert {:error, :timeout} = Durable.update_object(state, key, never, timeout: 10)
  end

  test "deletes over its etag, and says what is not there", %{state: state} do
    key = unique()
    {:ok, %{etag: first}} = Durable.put_object(state, key, 1, [])
    {:ok, %{etag: second}} = Durable.put_object(state, key, 2, etag: first)

    assert {:error, :conflict} = Durable.delete_object(state, key, etag: first)
    assert {:error, :conflict} = Durable.delete_object(state, key, etag: "not an etag")
    assert :ok = Durable.delete_object(state, key, etag: second)
    assert {:error, :not_found} = Durable.delete_object(state, key)

    {:ok, _object} = Durable.put_object(state, key, 3, [])
    assert :ok = Durable.delete_object(state, key)
  end

  test "a delete that races a write conflicts", %{state: state} do
    key = unique()
    {:ok, %{etag: etag}} = Durable.put_object(state, key, 1, [])

    Mimic.expect(Impl, :delete, fn store, ns, key, _opts ->
      {:ok, _raced} = Impl.put(store, ns, key, 2, [])
      {:error, :conflict}
    end)

    assert {:error, :conflict} = Durable.delete_object(state, key, etag: etag)

    Mimic.expect(Impl, :delete, fn store, ns, key, _opts ->
      :ok = Impl.delete(store, ns, key, [])
      {:error, :conflict}
    end)

    assert {:error, :not_found} = Durable.delete_object(state, key, [])

    {:ok, _object} = Durable.put_object(state, key, 1, [])
    Mimic.expect(Impl, :delete, fn _store, _ns, _key, _opts -> {:error, :unavailable} end)
    assert {:error, :unavailable} = Durable.delete_object(state, key)
  end

  test "lists under a prefix, with bodies where asked", %{state: state} do
    prefix = unique() <> "/"
    {:ok, %{etag: etag}} = Durable.put_object(state, prefix <> "a", 1, [])

    assert [%{key: key, etag: ^etag}] =
             Enum.to_list(Durable.list_all_objects_stream(state, prefix, []))

    assert key == prefix <> "a"

    assert [%{body: 1}] =
             Enum.to_list(Durable.list_all_objects_stream(state, prefix, include_objects: true))

    Mimic.expect(Impl, :lookup, fn _store, _ns, _key -> nil end)
    assert Enum.to_list(Durable.list_all_objects_stream(state, prefix, [])) == []
  end

  test "hands an object it cannot read to the error handler, and leaves it out", %{
    state: state,
    store: store
  } do
    prefix = unique() <> "/"

    {:ok, _vsn} =
      WardrikStore.put(store, :durable, prefix <> "bad", %{vsn: 1, state: %{}, meta: :bad})

    test = self()

    assert [] =
             state
             |> Durable.list_all_objects_stream(prefix,
               include_objects: true,
               error_handler: &send(test, &1)
             )
             |> Enum.to_list()

    assert_received {:decode_failed, key, %ArgumentError{}}
    assert key == prefix <> "bad"
    assert {:error, %ArgumentError{}} = Durable.get_object(state, key, [])
  end

  test "keeps a server's metadata and state as encoded binaries, and reads them back", %{
    state: state,
    store: store
  } do
    key = unique()
    {:ok, _object} = Durable.put_object(state, key, stored(self()), [])

    assert {%{"meta" => meta, "state" => kept}, _vsn} = WardrikStore.lookup(store, :durable, key)
    assert is_binary(meta) and is_binary(kept)

    assert {:ok, %{body: %StoredState{state: %{"turns" => 1}, meta: %Meta{pid: pid}}}} =
             Durable.get_object(state, key, [])

    assert pid == self()
  end

  test "reads metadata an earlier version kept as a term", %{state: state, store: store} do
    key = unique()

    {:ok, _vsn} =
      WardrikStore.put(store, :durable, key, StoredState.to_storage_term(stored(self())))

    assert {:ok, %{body: %StoredState{meta: %Meta{pid: pid}}}} =
             Durable.get_object(state, key, [])

    assert pid == self()
  end

  test "an object its store cannot decode stops no other being read", %{state: state} do
    prefix = unique() <> "/"
    {:ok, _object} = Durable.put_object(state, prefix <> "good", stored(self()), [])
    {:ok, _object} = Durable.put_object(state, prefix <> "unreadable", stored(self()), [])

    Mimic.stub(Impl, :lookup, fn store, ns, key ->
      if String.ends_with?(key, "unreadable"),
        do: raise(ArgumentError, "invalid or unsafe external representation of a term"),
        else: Mimic.call_original(Impl, :lookup, [store, ns, key])
    end)

    test = self()

    assert [%{key: good}] =
             state
             |> Durable.list_all_objects_stream(prefix,
               include_objects: true,
               error_handler: &send(test, &1)
             )
             |> Enum.to_list()

    assert good == prefix <> "good"
    assert_received {:decode_failed, unreadable, %ArgumentError{}}
    assert unreadable == prefix <> "unreadable"
    assert {:error, %ArgumentError{}} = Durable.get_object(state, unreadable, [])
    assert {:error, %ArgumentError{}} = Durable.delete_object(state, unreadable)
  end

  test "takes an object whose state it cannot read as absent, and claims over it", %{
    state: state,
    store: store
  } do
    key = unique()
    {:ok, _object} = Durable.put_object(state, key, stored(self()), [])

    # A state naming an atom this node has never made, as one naming a field
    # this release does not have would.
    name = "unmade_#{System.unique_integer([:positive])}"
    {value, _vsn} = WardrikStore.lookup(store, :durable, key)
    unreadable = %{value | "state" => <<131, 119, byte_size(name), name::binary>>}
    {:ok, _vsn} = WardrikStore.put(store, :durable, key, unreadable)

    assert {:error, :not_found} = Durable.get_object(state, key, [])
    assert [] = Enum.to_list(Durable.list_all_objects_stream(state, key, include_objects: true))

    assert capture_log(fn ->
             assert {:ok, {:claimed, _etag}} = Durable.try_claim(state, key, stored(self()))
           end) =~ "#{key} held a state this release cannot read"

    assert {:ok, %{body: %StoredState{state: %{"turns" => 1}}}} =
             Durable.get_object(state, key, [])

    assert {:error, :already_claimed} = Durable.try_claim(state, key, stored(self()))
  end

  test "passes through data that is no stored state", %{state: state} do
    assert Durable.encode(state, %{"heartbeat" => 1}) == {:ok, %{"heartbeat" => 1}}
    assert Durable.decode(state, %{"heartbeat" => 1}) == {:ok, %{"heartbeat" => 1}}
  end

  test "holds a DurableServer through a restart", %{store: store} do
    WardrikStore.Test.Durable.survives_a_restart(store, :durable_over_memory)
  end

  defp unique, do: "durable-test/#{System.unique_integer([:positive])}"

  defp stored(pid),
    do: %StoredState{
      vsn: 1,
      state: %{"turns" => 1},
      meta: %Meta{module: __MODULE__, pid: pid, status: :running}
    }
end
