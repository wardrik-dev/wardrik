defmodule Wardrik.Store.DurableTest do
  use ExUnit.Case, async: false

  alias Wardrik.Store.Durable
  alias Wardrik.Store.Memory

  setup_all do
    start_supervised!(Memory.child_spec([]))
    {:ok, %{state: state} = backend} = Durable.init_backend(store: Memory)
    %{state: state, backend: backend}
  end

  test "polls for heartbeats, at the intervals it was given", %{backend: backend} do
    assert backend.defaults == %{
             heartbeat_tracking_mode: :poll,
             discovery_interval_ms: 30_000,
             heartbeat_interval_ms: 10_000,
             heartbeat_reconcile_interval_ms: 10_000
           }

    assert {:ok, %{defaults: %{discovery_interval_ms: 5}}} =
             Durable.init_backend(%{store: Memory, discovery_interval_ms: 5})

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

    Mimic.expect(Memory, :delete, fn ns, key, _opts ->
      {:ok, _raced} = Memory.put(ns, key, 2, [])
      {:error, :conflict}
    end)

    assert {:error, :conflict} = Durable.delete_object(state, key, etag: etag)

    Mimic.expect(Memory, :delete, fn ns, key, _opts ->
      :ok = Memory.delete(ns, key, [])
      {:error, :conflict}
    end)

    assert {:error, :not_found} = Durable.delete_object(state, key, [])

    {:ok, _object} = Durable.put_object(state, key, 1, [])
    Mimic.expect(Memory, :delete, fn _ns, _key, _opts -> {:error, :unavailable} end)
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

    Mimic.expect(Memory, :lookup, fn _ns, _key -> nil end)
    assert Enum.to_list(Durable.list_all_objects_stream(state, prefix, [])) == []
  end

  test "hands an object it cannot read to the error handler, and leaves it out", %{state: state} do
    prefix = unique() <> "/"
    {:ok, _vsn} = Memory.put(:durable, prefix <> "bad", %{vsn: 1, state: %{}, meta: :bad}, [])
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

  test "passes through data that is no stored state", %{state: state} do
    assert Durable.encode(state, %{"heartbeat" => 1}) == {:ok, %{"heartbeat" => 1}}
    assert Durable.decode(state, %{"heartbeat" => 1}) == {:ok, %{"heartbeat" => 1}}
  end

  test "holds a DurableServer through a restart" do
    Wardrik.Test.Durable.survives_a_restart(Memory, :durable_over_memory)
  end

  defp unique, do: "durable-test/#{System.unique_integer([:positive])}"
end
