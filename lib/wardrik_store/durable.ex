if Code.ensure_loaded?(DurableServer.StorageBackend) do
  defmodule WardrikStore.Durable do
    @moduledoc """
    A `DurableServer` backend that keeps WardrikCore's agents in a store.

        {WardrikCore, backend: {WardrikStore.Durable, store: store}}

    Agents are kept under the store's `durable` scope.

    ## Options

      * `:store` - required. The `WardrikStore` to keep agents in.
      * `:heartbeat_interval_ms` - `10_000` unless set.
      * `:discovery_interval_ms` - `30_000` unless set.
    """

    @behaviour DurableServer.StorageBackend

    require Logger

    alias DurableServer.StoredState

    @max_retries 5

    @impl DurableServer.StorageBackend
    def init_backend(opts) when is_map(opts), do: opts |> Map.to_list() |> init_backend()

    def init_backend(opts) do
      heartbeat = Keyword.get(opts, :heartbeat_interval_ms, 10_000)

      {:ok,
       %{
         state: WardrikStore.scope(Keyword.fetch!(opts, :store), "durable"),
         defaults: %{
           heartbeat_tracking_mode: :poll,
           discovery_interval_ms: Keyword.get(opts, :discovery_interval_ms, 30_000),
           heartbeat_interval_ms: heartbeat,
           heartbeat_reconcile_interval_ms: heartbeat
         },
         features: %{list_includes_body?: true, conditional_delete?: true}
       }}
    end

    @impl DurableServer.StorageBackend
    def ensure_ready(_store), do: :ok

    @impl DurableServer.StorageBackend
    def get_object(store, key, _opts) do
      with {value, vsn} <- WardrikStore.lookup(store, key),
           {:ok, body} <- body(value) do
        {:ok, %{body: body, etag: etag(vsn)}}
      else
        _missing_or_unreadable -> {:error, :not_found}
      end
    end

    @impl DurableServer.StorageBackend
    def list_all_objects_stream(store, prefix, opts) do
      with_body? = Keyword.get(opts, :include_objects, false)
      error_handler = Keyword.get(opts, :error_handler, fn _reason -> :continue end)

      listed(store, prefix, with_body?, error_handler)
    end

    @impl DurableServer.StorageBackend
    def put_object(store, key, data, opts) do
      with {:ok, put_opts} <- condition(opts),
           {:ok, vsn} <- WardrikStore.put(store, key, stored(data), put_opts) do
        {:ok, %{body: data, etag: etag(vsn)}}
      end
    end

    @impl DurableServer.StorageBackend
    def delete_object(store, key), do: delete_object(store, key, [])

    @impl DurableServer.StorageBackend
    def delete_object(store, key, opts) do
      with {_value, current} <- WardrikStore.lookup(store, key),
           {:ok, vsn} <- expected(opts, current) do
        store |> WardrikStore.delete(key, if_vsn: vsn) |> deleted(store, key)
      else
        nil -> {:error, :not_found}
        {:error, reason} -> {:error, reason}
      end
    end

    @impl DurableServer.StorageBackend
    def try_claim(store, key, body) do
      case WardrikStore.put(store, key, stored(body), if_vsn: nil) do
        {:ok, vsn} -> {:ok, {:claimed, etag(vsn)}}
        {:error, :conflict} -> claim_unreadable(store, key, body)
        {:error, reason} -> {:error, reason}
      end
    end

    @impl DurableServer.StorageBackend
    def update_object(store, key, update, opts),
      do: update(store, key, update, Keyword.get(opts, :max_retries, @max_retries))

    @impl DurableServer.StorageBackend
    def encode(_store, data), do: {:ok, stored(data)}

    @impl DurableServer.StorageBackend
    def decode(_store, data), do: body(data)

    defp listed(store, prefix, true, error_handler) do
      for {key, value, vsn} <- WardrikStore.entries(store, prefix),
          listed <- listed_with_body(key, value, vsn, error_handler),
          do: listed
    end

    defp listed(store, prefix, false, _error_handler),
      do:
        for({key, vsn} <- WardrikStore.versions(store, prefix), do: %{key: key, etag: etag(vsn)})

    defp listed_with_body(key, value, vsn, error_handler) do
      case body(value) do
        {:ok, body} ->
          [%{key: key, etag: etag(vsn), body: body}]

        {:error, reason} ->
          _handled = error_handler.({:decode_failed, key, reason})
          []
      end
    end

    defp claim_unreadable(store, key, body) do
      with {value, vsn} <- WardrikStore.lookup(store, key),
           {:error, :unreadable} <- body(value),
           {:ok, vsn} <- WardrikStore.put(store, key, stored(body), if_vsn: vsn) do
        Logger.warning("#{key} held a state this release can't read, so it was claimed as new")
        {:ok, {:claimed, etag(vsn)}}
      else
        _held -> {:error, :already_claimed}
      end
    end

    defp update(_store, _key, _update, retries) when retries < 0,
      do: {:error, :max_retries_exceeded}

    defp update(store, key, update, retries) do
      with {:ok, current} <- get_object(store, key, []),
           {:ok, data} <- update.(current) do
        case put_object(store, key, data, etag: current.etag) do
          {:error, :conflict} -> update(store, key, update, retries - 1)
          result -> result
        end
      end
    end

    defp condition(opts) do
      case Keyword.fetch(opts, :etag) do
        {:ok, etag} -> with {:ok, vsn} <- vsn(etag), do: {:ok, [if_vsn: vsn]}
        :error -> {:ok, []}
      end
    end

    defp expected(opts, current) do
      case Keyword.fetch(opts, :etag) do
        {:ok, etag} -> vsn(etag)
        :error -> {:ok, current}
      end
    end

    defp deleted(:ok, _store, _key), do: :ok

    defp deleted({:error, :conflict}, store, key) do
      if WardrikStore.lookup(store, key) == nil,
        do: {:error, :not_found},
        else: {:error, :conflict}
    end

    defp deleted({:error, reason}, _store, _key), do: {:error, reason}

    defp stored(%StoredState{} = stored_state) do
      %{
        StoredState.to_object_store_term(stored_state)
        | "state" => :erlang.term_to_binary(stored_state.state)
      }
    end

    defp stored(data), do: data

    defp body(value) do
      case StoredState.from_object_store_term(value) do
        {:ok, stored_state} -> with_state(stored_state)
        {:error, _reason} -> {:error, :unreadable}
        :not_stored_state -> {:ok, value}
      end
    end

    defp with_state(%StoredState{state: state} = stored_state) do
      {:ok, %{stored_state | state: :erlang.binary_to_term(state, [:safe])}}
    rescue
      ArgumentError -> {:error, :unreadable}
    end

    defp etag(vsn), do: vsn |> :erlang.term_to_binary() |> Base.url_encode64(padding: false)

    defp vsn(etag) when is_binary(etag) do
      case Base.url_decode64(etag, padding: false) do
        {:ok, binary} -> {:ok, :erlang.binary_to_term(binary, [:safe])}
        :error -> {:error, :conflict}
      end
    rescue
      ArgumentError -> {:error, :conflict}
    end

    defp vsn(_etag), do: {:error, :conflict}
  end
end
