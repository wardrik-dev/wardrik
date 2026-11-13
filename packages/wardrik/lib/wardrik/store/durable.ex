if Code.ensure_loaded?(DurableServer.StorageBackend) do
  defmodule Wardrik.Store.Durable do
    @moduledoc """
    A `DurableServer` backend that keeps WardrikCore's agents in a store.

        {WardrikCore, backend: {Wardrik.Store.Durable, store: store}}

    Agents are kept under the store's `durable` scope.

    A saved state this release can't read, such as one naming a module it no longer has, is
    never replaced or skipped quietly:

      * It's noted with why, once for each version of it, with a warning. See `noted/2`.
      * Discovery passes it over, and starting it again is refused with
        `{:unreadable, reason}`. Only `discard/2` removes it.

    ## Options

      * `:store` - required. The `Wardrik.Store` to keep agents in.
      * `:heartbeat_interval_ms` - `10_000` unless set.
      * `:discovery_interval_ms` - `30_000` unless set.
    """

    @behaviour DurableServer.StorageBackend

    require Logger

    alias DurableServer.StoredState
    alias Wardrik.Store.Durable.Unreadable

    @max_retries 5

    @impl DurableServer.StorageBackend
    def init_backend(opts) when is_map(opts), do: opts |> Map.to_list() |> init_backend()

    def init_backend(opts) do
      heartbeat = Keyword.get(opts, :heartbeat_interval_ms, 10_000)

      {:ok,
       %{
         state: Wardrik.Store.scope(Keyword.fetch!(opts, :store), "durable"),
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
      case Wardrik.Store.lookup(store, key) do
        {value, vsn} -> read(store, key, value, vsn)
        nil -> {:error, :not_found}
      end
    end

    # DurableServer takes a state it can't load as never written; try_claim/3 then refuses it.
    defp read(store, key, value, vsn) do
      case body(value) do
        {:ok, body} ->
          {:ok, %{body: body, etag: etag(vsn)}}

        {:error, reason} ->
          note(store, key, reason, vsn)
          {:error, :not_found}
      end
    end

    @impl DurableServer.StorageBackend
    def list_all_objects_stream(store, prefix, opts) do
      with_body? = Keyword.get(opts, :include_objects, false)
      listed(store, prefix, with_body?)
    end

    @impl DurableServer.StorageBackend
    def put_object(store, key, data, opts) do
      with {:ok, put_opts} <- condition(opts),
           {:ok, vsn} <- Wardrik.Store.put(store, key, stored(data), put_opts) do
        {:ok, %{body: data, etag: etag(vsn)}}
      end
    end

    @impl DurableServer.StorageBackend
    def delete_object(store, key), do: delete_object(store, key, [])

    @impl DurableServer.StorageBackend
    def delete_object(store, key, opts) do
      with {_value, current} <- Wardrik.Store.lookup(store, key),
           {:ok, vsn} <- expected(opts, current) do
        store |> Wardrik.Store.delete(key, if_vsn: vsn) |> deleted(store, key)
      else
        nil -> {:error, :not_found}
        {:error, reason} -> {:error, reason}
      end
    end

    @impl DurableServer.StorageBackend
    def try_claim(store, key, body) do
      case Wardrik.Store.put(store, key, stored(body), if_vsn: nil) do
        {:ok, vsn} -> {:ok, {:claimed, etag(vsn)}}
        {:error, :conflict} -> held(store, key)
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

    defp listed(store, prefix, true) do
      for {key, value, vsn} <- Wardrik.Store.entries(store, prefix),
          listed <- listed_with_body(store, key, value, vsn),
          do: listed
    end

    defp listed(store, prefix, false),
      do:
        for({key, vsn} <- Wardrik.Store.versions(store, prefix), do: %{key: key, etag: etag(vsn)})

    defp listed_with_body(store, key, value, vsn) do
      case body(value) do
        {:ok, body} ->
          [%{key: key, etag: etag(vsn), body: body}]

        {:error, reason} ->
          note(store, key, reason, vsn)
          []
      end
    end

    defp held(store, key) do
      with {value, vsn} <- Wardrik.Store.lookup(store, key),
           {:error, reason} <- body(value) do
        note(store, key, reason, vsn)
        {:error, {:unreadable, reason}}
      else
        _held -> {:error, :already_claimed}
      end
    end

    @doc """
    Returns why the saved state `key` can't be read, if a read found it so and it hasn't been
    written since. `store` is the one given as `:store`.

        Wardrik.Store.Durable.noted(store, "wardrik/agents/acme.drafts")
        #=> {:ok, "it names WardrikPolicy, which this release doesn't have"}
    """
    @spec noted(Wardrik.Store.t(), String.t()) :: {:ok, String.t()} | :error
    def noted(store, key) do
      durable = durable(store)

      with {%{"reason" => reason, "vsn" => vsn}, _note_vsn} <-
             Wardrik.Store.lookup(notes(durable), key),
           {^key, ^vsn} <- List.keyfind(Wardrik.Store.versions(durable, key), key, 0) do
        {:ok, reason}
      else
        _none -> :error
      end
    end

    @doc """
    Reads the saved state `key`. Returns `:ok` if it's readable or there's none, or why it
    can't be read, noting it as `noted/2` returns it.
    """
    @spec check(Wardrik.Store.t(), String.t()) :: :ok | {:error, String.t()}
    def check(store, key) do
      durable = durable(store)

      with {value, vsn} <- Wardrik.Store.lookup(durable, key),
           {:error, reason} <- body(value) do
        note(durable, key, reason, vsn)
        {:error, reason}
      else
        _readable_or_none -> :ok
      end
    end

    @doc "Removes the saved state `key` and its note, as when starting it over."
    @spec discard(Wardrik.Store.t(), String.t()) :: :ok | {:error, term()}
    def discard(store, key) do
      durable = durable(store)

      with :ok <- Wardrik.Store.delete(durable, key),
           do: Wardrik.Store.delete(notes(durable), key)
    end

    defp note(store, key, reason, vsn) do
      notes = notes(store)

      case Wardrik.Store.lookup(notes, key) do
        {%{"vsn" => ^vsn}, _note_vsn} ->
          :ok

        _new ->
          {:ok, _note_vsn} = Wardrik.Store.put(notes, key, %{"reason" => reason, "vsn" => vsn})
          Logger.warning("The saved state #{key} can't be read: #{reason}.")
      end
    end

    defp durable(store), do: Wardrik.Store.scope(store, "durable")
    defp notes(durable), do: Wardrik.Store.scope(durable, "unreadable")

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
      if Wardrik.Store.lookup(store, key) == nil,
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
        {:ok, stored_state} -> with_state(stored_state, :first)
        {:error, _reason} -> {:error, "it isn't in a form this release can read"}
        :not_stored_state -> {:ok, value}
      end
    end

    # A module not loaded yet, as in development, is loaded before the state is called unreadable.
    defp with_state(%StoredState{state: state} = stored_state, attempt) do
      case safe(state) do
        {:ok, term} ->
          {:ok, %{stored_state | state: term}}

        :error ->
          if attempt == :first and Unreadable.load_named(state),
            do: with_state(stored_state, :again),
            else: {:error, Unreadable.reason(state)}
      end
    end

    # The safe decode raises for an atom this release doesn't have.
    defp safe(binary) do
      {:ok, :erlang.binary_to_term(binary, [:safe])}
    rescue
      ArgumentError -> :error
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
