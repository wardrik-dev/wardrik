defmodule WardrikStore.Durable do
  @moduledoc """
  A `DurableServer` backend over a `WardrikStore` adapter, so agents are kept
  in the same store as everything else.

      {WardrikStore.Durable, store: store, discovery_interval_ms: 5_000}

  An adapter names it from its `WardrikStore.Adapter.durable_backend/1`. Every
  object is a key in the `:durable` namespace, under the prefix its
  supervisor names, such as `agents/`, and its etag is the version the adapter
  wrote it with. A claim is a write where nothing is written, and an
  update is a write over the version read, retried with a backoff while
  another writer keeps getting there first.

  The adapter's reads are taken as current: `lookup/2` must answer the last
  write, on every node. `WardrikEcto.Store` and `WardrikS3.Store` do.
  `WardrikStore.EKV` names DurableServer's own EKV backend instead.

  A server's metadata names the process that holds it, and so the node that
  process ran on. It is kept as DurableServer's object stores keep it, an
  encoded binary DurableServer reads back itself, not as a term the adapter
  decodes: an adapter decodes with `[:safe]`, which refuses a node name the
  reading VM has never seen, and a node that replaces another under a new
  name, as a rolling deploy starts one, has seen none of the names before
  it. Metadata kept as a term by earlier versions is still read, and is kept
  as a binary when its server is next written. An object the adapter cannot
  decode is left out of listings, through the caller's error handler, and
  answered as an error, so it stops no other object being read.

  A server's state is kept as a binary too, which this backend decodes with
  `[:safe]`, so one a release cannot read, such as one naming a field it no
  longer has, leaves the object's version readable. Such an object is taken
  as absent: a read answers it is not found, a listing leaves it out, and a
  claim writes over it with a warning naming its key, so the server starts
  as one never written.

  | Option | Default | |
  | --- | --- | --- |
  | `:store` | required | the `WardrikStore` |
  | `:namespace` | `:durable` | where objects are kept |
  | `:discovery_interval_ms` | 30s | how often a node looks for work no node holds |
  | `:heartbeat_interval_ms` | 10s | how often a node says it is alive |

  Heartbeats are objects too, read by polling, so a node that stops is noticed
  within a heartbeat or two, and its work is taken up at the next discovery.
  """

  @behaviour DurableServer.StorageBackend

  require Logger

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
    case read(state, key) do
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
      {value, vsn} -> with {:error, :unreadable} <- object(value, vsn), do: {:error, :not_found}
    end
  end

  @impl true
  def list_all_objects_stream(state, prefix, opts) do
    include_objects = Keyword.get(opts, :include_objects, false)
    error_handler = Keyword.get(opts, :error_handler, fn _reason -> :continue end)

    WardrikStore.keys(state.store, state.ns, prefix)
    |> Stream.flat_map(fn key -> listed(state, key, include_objects, error_handler) end)
  end

  # An object that cannot be read is handed to the caller's error handler and
  # left out.
  defp listed(state, key, include_objects, error_handler) do
    case read(state, key) do
      nil ->
        []

      {:error, reason} ->
        _handled = error_handler.({:decode_failed, key, reason})
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
         {:ok, vsn} <- WardrikStore.put(state.store, state.ns, key, term(data), put_opts) do
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
    case {Keyword.fetch(opts, :etag), read(state, key)} do
      {_etag, nil} -> {:error, :not_found}
      {{:ok, etag}, _current} -> with {:ok, vsn} <- vsn(etag), do: deleted(state, key, vsn)
      {:error, {:error, reason}} -> {:error, reason}
      {:error, {_value, vsn}} -> deleted(state, key, vsn)
    end
  end

  defp deleted(state, key, vsn) do
    case WardrikStore.delete(state.store, state.ns, key, if_vsn: vsn) do
      :ok ->
        :ok

      {:error, :conflict} ->
        if read(state, key) == nil,
          do: {:error, :not_found},
          else: {:error, :conflict}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def try_claim(state, key, body) do
    case WardrikStore.put(state.store, state.ns, key, term(body), if_vsn: nil) do
      {:ok, vsn} -> {:ok, {:claimed, etag(vsn)}}
      {:error, :conflict} -> claim_unreadable(state, key, body)
      {:error, reason} -> {:error, reason}
    end
  end

  defp claim_unreadable(state, key, body) do
    with {value, vsn} <- read(state, key),
         {:error, :unreadable} <- body(value),
         {:ok, vsn} <- WardrikStore.put(state.store, state.ns, key, term(body), if_vsn: vsn) do
      Logger.warning("#{key} held a state this release cannot read; it is claimed as new")
      {:ok, {:claimed, etag(vsn)}}
    else
      _held -> {:error, :already_claimed}
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

  # An adapter raises on a value it cannot decode.
  defp read(state, key) do
    WardrikStore.lookup(state.store, state.ns, key)
  rescue
    error in ArgumentError -> {:error, error}
  end

  defp body(value) do
    with :not_stored_state <- stored_state(value),
         :not_stored_state <- StoredState.from_storage_term(value) do
      {:ok, value}
    end
  end

  defp stored_state(value) do
    with {:ok, stored_state} <- StoredState.from_object_store_term(value),
         do: {:ok, %{stored_state | state: :erlang.binary_to_term(stored_state.state, [:safe])}}
  rescue
    ArgumentError -> {:error, :unreadable}
  end

  defp term(%StoredState{} = stored_state) do
    %{
      StoredState.to_object_store_term(stored_state)
      | "state" => :erlang.term_to_binary(stored_state.state)
    }
  end

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
