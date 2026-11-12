defmodule WardrikStore.DurableConformance do
  @moduledoc "The tests `WardrikStore.Durable` passes over a store, run on the store under `:store`."

  defmacro __using__(_opts) do
    quote do
      import ExUnit.CaptureLog
      import WardrikStore.Conformance, only: [unique_key: 1]

      alias DurableServer.Meta
      alias DurableServer.StoredState
      alias WardrikStore.Durable

      describe "a Durable backend" do
        setup %{store: store} do
          {:ok, %{state: backend}} = Durable.init_backend(store: store)
          %{backend: backend}
        end

        test "writes only over the version it was given", %{backend: backend} = context do
          key = unique_key(context)

          {:ok, %{etag: first}} = Durable.put_object(backend, key, 1, [])
          {:ok, %{etag: second}} = Durable.put_object(backend, key, 2, etag: first)

          assert {:error, :conflict} = Durable.put_object(backend, key, 3, etag: first)
          assert {:error, :conflict} = Durable.put_object(backend, key, 3, etag: "not an etag")
          assert {:ok, %{body: 2, etag: ^second}} = Durable.get_object(backend, key, [])
        end

        test "claims a key once", %{backend: backend} = context do
          key = unique_key(context)

          assert {:ok, {:claimed, _etag}} = Durable.try_claim(backend, key, 1)
          assert {:error, :already_claimed} = Durable.try_claim(backend, key, 2)
        end

        test "deletes only the version it was given", %{backend: backend} = context do
          key = unique_key(context)

          {:ok, %{etag: first}} = Durable.put_object(backend, key, 1, [])
          {:ok, _object} = Durable.put_object(backend, key, 2, [])

          assert {:error, :conflict} = Durable.delete_object(backend, key, etag: first)
          assert :ok = Durable.delete_object(backend, key)
          assert {:error, :not_found} = Durable.delete_object(backend, key)
          assert {:error, :not_found} = Durable.get_object(backend, key, [])
        end

        test "updates what's there", %{backend: backend} = context do
          key = unique_key(context)
          {:ok, _object} = Durable.put_object(backend, key, 1, [])

          assert {:ok, %{body: 2}} =
                   Durable.update_object(backend, key, fn %{body: n} -> {:ok, n + 1} end, [])

          assert {:error, :not_found} =
                   Durable.update_object(backend, unique_key(context), &{:ok, &1}, [])
        end

        test "updates again when another writer got there first", %{backend: backend} = context do
          key = unique_key(context)
          {:ok, _object} = Durable.put_object(backend, key, 1, [])

          racing = fn %{body: body} ->
            if body == 1, do: {:ok, _raced} = Durable.put_object(backend, key, 10, [])
            {:ok, body + 1}
          end

          assert {:ok, %{body: 11}} = Durable.update_object(backend, key, racing, [])
        end

        test "gives up updating when other writers keep getting there first",
             %{backend: backend} = context do
          key = unique_key(context)
          {:ok, _object} = Durable.put_object(backend, key, 1, [])

          always_racing = fn %{body: body} ->
            {:ok, _raced} = Durable.put_object(backend, key, body, [])
            {:ok, body}
          end

          assert {:error, :max_retries_exceeded} =
                   Durable.update_object(backend, key, always_racing, max_retries: 2)
        end

        test "round-trips what it encodes", %{store: store} do
          {:ok, %{state: backend} = init} = Durable.init_backend(%{store: store})
          stored = %StoredState{vsn: 1, state: %{count: 3}, meta: %Meta{}}

          assert :ok = Durable.ensure_ready(backend)
          assert init.defaults.heartbeat_tracking_mode == :poll
          assert {:ok, encoded} = Durable.encode(backend, stored)
          assert {:ok, %StoredState{state: %{count: 3}}} = Durable.decode(backend, encoded)
          assert {:error, :conflict} = Durable.put_object(backend, "a", 1, etag: nil)
        end

        test "lists the keys under a prefix", %{backend: backend} = context do
          prefix = unique_key(context) <> "/"
          {:ok, _object} = Durable.put_object(backend, prefix <> "a", 1, [])

          assert [%{key: key} = listed] =
                   backend |> Durable.list_all_objects_stream(prefix, []) |> Enum.to_list()

          assert key == prefix <> "a"
          refute Map.has_key?(listed, :body)

          assert [%{body: 1}] =
                   backend
                   |> Durable.list_all_objects_stream(prefix, include_objects: true)
                   |> Enum.to_list()
        end

        test "keeps a server's state and metadata", %{backend: backend} = context do
          key = unique_key(context)
          stored = %StoredState{vsn: 1, state: %{count: 3}, meta: %Meta{}}

          {:ok, _object} = Durable.put_object(backend, key, stored, [])

          assert {:ok, %{body: %StoredState{vsn: 1, state: %{count: 3}}}} =
                   Durable.get_object(backend, key, [])
        end

        test "takes a state it can't read as never written", %{store: store} = context do
          key = unique_key(context)
          {:ok, %{state: backend}} = Durable.init_backend(store: store)
          stored = %StoredState{vsn: 1, state: %{}, meta: %Meta{}}
          unreadable = %{"vsn" => 1, "state" => <<131, 100, 0, 3, "zzq">>, "meta" => "x"}

          {:ok, _vsn} = WardrikStore.put(WardrikStore.scope(store, "durable"), key, unreadable)

          assert {:error, :not_found} = Durable.get_object(backend, key, [])

          parent = self()
          handler = fn reason -> send(parent, {:handled, reason}) end

          assert [] =
                   backend
                   |> Durable.list_all_objects_stream(key,
                     include_objects: true,
                     error_handler: handler
                   )
                   |> Enum.to_list()

          assert_receive {:handled, {:decode_failed, ^key, :unreadable}}

          assert capture_log(fn ->
                   assert {:ok, {:claimed, _etag}} = Durable.try_claim(backend, key, stored)
                 end) =~ "claimed as new"
        end
      end
    end
  end
end
