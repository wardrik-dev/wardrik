defmodule Wardrik.Store.Durable do
  @moduledoc """
  A `DurableServer` backend over a `Wardrik.Store` adapter, so agents are kept
  in the same store as everything else.

      {Wardrik.Store.Durable, store: WardrikEcto.Store, discovery_interval_ms: 5_000}

  An adapter names it from its `c:Wardrik.Store.durable_backend/1`. Every
  object is a key in the `:durable` namespace, and its etag is the version the
  adapter wrote it with. A claim is a write where nothing is written, and an
  update is a write over the version read, retried with a backoff while
  another writer keeps getting there first.

  The adapter's reads are taken as current: `lookup/2` must answer the last
  write, on every node. `WardrikEcto.Store` and `WardrikS3.Store` do.
  `Wardrik.Store.EKV` names DurableServer's own EKV backend instead.

  | Option | Default | |
  | --- | --- | --- |
  | `:store` | required | the adapter |
  | `:namespace` | `:durable` | where objects are kept |
  | `:discovery_interval_ms` | 30s | how often a node looks for work no node holds |
  | `:heartbeat_interval_ms` | 10s | how often a node says it is alive |

  Heartbeats are objects too, read by polling, so a node that stops is noticed
  within a heartbeat or two, and its work is taken up at the next discovery.
  """

  @behaviour DurableServer.StorageBackend

  alias DurableServer.StoredState

  @defaults [namespace: :durable, discovery_interval_ms: 30_000, heartbeat_interval_ms: 10_000]
  @max_retries 5

  @impl true
  def init_backend(opts) when is_list(opts) do
    opts = Keyword.merge(@defaults, opts)

    {:ok,
     %{
       state: %{store: Keyword.fetch!(opts, :store), ns: Keyword.fetch!(opts, :namespace)},
       defaults: %{
         heartbeat_tracking_mode: :poll,
         discovery_interval_ms: opts[:discovery_interval_ms],
         heartbeat_interval_ms: opts[:heartbeat_interval_ms],
         heartbeat_reconcile_interval_ms: opts[:heartbeat_interval_ms]
       },
       features: %{
         heartbeat_subscribe?: false,
         list_includes_body?: true,
         conditional_delete?: true
       }
     }}
  end

  def init_backend(opts) when is_map(opts), do: opts |> Map.to_list() |> init_backend()

  @impl true
  def ensure_ready(_state), do: :ok

  @impl true
  def get_object(state, key, _opts) do
    case state.store.lookup(state.ns, key) do
      nil -> {:error, :not_found}
      {value, vsn} -> object(value, vsn)
    end
  end

  @impl true
  def list_all_objects_stream(state, prefix, opts) do
    include_objects = Keyword.get(opts, :include_objects, false)
    error_handler = Keyword.get(opts, :error_handler, fn _reason -> :continue end)

    state.store.keys(state.ns, prefix)
    |> Stream.flat_map(fn key -> listed(state, key, include_objects, error_handler) end)
  end

  # An object that cannot be read is handed to the caller's error handler and
  # left out.
  defp listed(state, key, include_objects, error_handler) do
    case state.store.lookup(state.ns, key) do
      nil ->
        []

      {value, vsn} when include_objects ->
        case object(value, vsn) do
          {:ok, object} ->
            [Map.put(object, :key, key)]

          {:error, reason} ->
            _handled = error_handler.({:decode_failed, key, reason})
            []
        end

      {_value, vsn} ->
        [%{key: key, etag: etag(vsn)}]
    end
  end

  @impl true
  def put_object(state, key, data, opts) do
    with {:ok, put_opts} <- put_opts(opts),
         {:ok, vsn} <- state.store.put(state.ns, key, term(data), put_opts) do
      {:ok, %{body: data, etag: etag(vsn)}}
    end
  end

  defp put_opts(opts) do
    case Keyword.fetch(opts, :etag) do
      {:ok, etag} -> with {:ok, vsn} <- vsn(etag), do: {:ok, [if_vsn: vsn]}
      :error -> {:ok, []}
    end
  end

  @impl true
  def delete_object(state, key), do: delete_object(state, key, [])

  @impl true
  def delete_object(state, key, opts) do
    case {Keyword.fetch(opts, :etag), state.store.lookup(state.ns, key)} do
      {_etag, nil} -> {:error, :not_found}
      {{:ok, etag}, _current} -> with {:ok, vsn} <- vsn(etag), do: deleted(state, key, vsn)
      {:error, {_value, vsn}} -> deleted(state, key, vsn)
    end
  end

  defp deleted(state, key, vsn) do
    case state.store.delete(state.ns, key, if_vsn: vsn) do
      :ok ->
        :ok

      {:error, :conflict} ->
        if state.store.lookup(state.ns, key) == nil,
          do: {:error, :not_found},
          else: {:error, :conflict}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def try_claim(state, key, body) do
    case state.store.put(state.ns, key, term(body), if_vsn: nil) do
      {:ok, vsn} -> {:ok, {:claimed, etag(vsn)}}
      {:error, :conflict} -> {:error, :already_claimed}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def update_object(state, key, update_fn, opts) do
    max_retries = Keyword.get(opts, :max_retries, @max_retries)

    case Keyword.get(opts, :timeout, :infinity) do
      :infinity ->
        update(state, key, update_fn, max_retries, 0)

      timeout ->
        task = Task.async(fn -> update(state, key, update_fn, max_retries, 0) end)

        case Task.yield(task, timeout) || Task.shutdown(task) do
          {:ok, result} -> result
          _timed_out -> {:error, :timeout}
        end
    end
  end

  defp update(_state, _key, _update_fn, max_retries, attempt) when attempt > max_retries,
    do: {:error, :max_retries_exceeded}

  defp update(state, key, update_fn, max_retries, attempt) do
    with {:ok, %{etag: etag} = current} <- get_object(state, key, []),
         {:ok, data} <- update_fn.(current) do
      case put_object(state, key, data, etag: etag) do
        {:error, :conflict} ->
          Process.sleep(backoff(attempt))
          update(state, key, update_fn, max_retries, attempt + 1)

        result ->
          result
      end
    end
  end

  defp backoff(attempt), do: :rand.uniform(10 * Integer.pow(2, min(attempt, 6)))

  @impl true
  def encode(_state, data), do: {:ok, term(data)}

  @impl true
  def decode(_state, data), do: body(data)

  defp object(value, vsn) do
    with {:ok, body} <- body(value), do: {:ok, %{body: body, etag: etag(vsn)}}
  end

  defp body(value) do
    case StoredState.from_storage_term(value) do
      {:ok, stored_state} -> {:ok, stored_state}
      :not_stored_state -> {:ok, value}
      {:error, reason} -> {:error, reason}
    end
  end

  defp term(%StoredState{} = stored_state), do: StoredState.to_storage_term(stored_state)
  defp term(data), do: data

  defp etag(vsn), do: vsn |> :erlang.term_to_binary() |> Base.url_encode64(padding: false)

  # An etag this backend did not give out names no version, so nothing
  # written can match it.
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
