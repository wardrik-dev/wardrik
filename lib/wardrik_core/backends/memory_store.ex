defmodule WardrikCore.Backends.MemoryStore do
  @moduledoc """
  Keeps agents in memory, until the node stops. For tests and trying things out.

      children = [
        {WardrikCore.Backends.MemoryStore, name: :agents},
        {WardrikCore, backend: {WardrikCore.Backends.MemoryStore, name: :agents}}
      ]
  """
  use GenServer

  @behaviour DurableServer.StorageBackend

  @doc "Starts the store. Takes a required `:name`."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, name, name: name)
  end

  @impl GenServer
  def init(name) do
    :ets.new(name, [:named_table, :set, :protected, read_concurrency: true])
    {:ok, name}
  end

  @impl GenServer
  def handle_call({:put, key, body, expected}, _from, table),
    do: {:reply, put(table, key, body, expected), table}

  def handle_call({:claim, key, body}, _from, table),
    do: {:reply, claim(table, key, body), table}

  def handle_call({:delete, key, expected}, _from, table),
    do: {:reply, delete(table, key, expected), table}

  @impl DurableServer.StorageBackend
  def init_backend(opts) do
    {:ok,
     %{
       state: Keyword.fetch!(opts, :name),
       defaults: %{heartbeat_tracking_mode: :poll},
       features: %{list_includes_body?: true, conditional_delete?: true}
     }}
  end

  @impl DurableServer.StorageBackend
  def ensure_ready(table) do
    if :ets.whereis(table) == :undefined, do: {:error, :not_started}, else: :ok
  end

  @impl DurableServer.StorageBackend
  def get_object(table, key, _opts) do
    case :ets.lookup(table, key) do
      [{^key, body, version}] -> {:ok, object(body, version)}
      [] -> {:error, :not_found}
    end
  end

  @impl DurableServer.StorageBackend
  def list_all_objects_stream(table, prefix, opts) do
    include_body? = Keyword.get(opts, :include_objects, false)

    table
    |> :ets.tab2list()
    |> Enum.filter(fn {key, _body, _version} -> String.starts_with?(key, prefix) end)
    |> Enum.map(fn {key, body, version} -> listed(key, body, version, include_body?) end)
  end

  @impl DurableServer.StorageBackend
  def put_object(table, key, body, opts),
    do: GenServer.call(table, {:put, key, body, Keyword.get(opts, :etag)})

  @impl DurableServer.StorageBackend
  def delete_object(table, key), do: delete_object(table, key, [])

  @impl DurableServer.StorageBackend
  def delete_object(table, key, opts),
    do: GenServer.call(table, {:delete, key, Keyword.get(opts, :etag)})

  @impl DurableServer.StorageBackend
  def try_claim(table, key, body), do: GenServer.call(table, {:claim, key, body})

  @impl DurableServer.StorageBackend
  def update_object(table, key, update, opts) do
    with {:ok, current} <- get_object(table, key, []),
         {:ok, body} <- update.(current) do
      table
      |> put_object(key, body, etag: current.etag)
      |> retry_on_conflict(table, key, update, opts)
    end
  end

  @impl DurableServer.StorageBackend
  def encode(_table, data), do: {:ok, data}

  @impl DurableServer.StorageBackend
  def decode(_table, data), do: {:ok, data}

  defp retry_on_conflict({:error, :conflict}, table, key, update, opts),
    do: update_object(table, key, update, opts)

  defp retry_on_conflict(result, _table, _key, _update, _opts), do: result

  defp put(table, key, body, expected) do
    case {version(table, key), expected} do
      {current, nil} -> write(table, key, body, current)
      {current, expected} -> write_if(table, key, body, current, expected)
    end
  end

  defp write_if(table, key, body, current, expected) do
    if etag(current) == expected, do: write(table, key, body, current), else: {:error, :conflict}
  end

  defp write(table, key, body, current) do
    version = (current || 0) + 1
    :ets.insert(table, {key, body, version})
    {:ok, object(body, version)}
  end

  defp claim(table, key, body) do
    if :ets.insert_new(table, {key, body, 1}),
      do: {:ok, {:claimed, etag(1)}},
      else: {:error, :already_claimed}
  end

  defp delete(table, key, expected) do
    case {version(table, key), expected} do
      {nil, _expected} -> {:error, :not_found}
      {_current, nil} -> remove(table, key)
      {current, expected} -> remove_if(table, key, current, expected)
    end
  end

  defp remove_if(table, key, current, expected) do
    if etag(current) == expected, do: remove(table, key), else: {:error, :conflict}
  end

  defp remove(table, key) do
    :ets.delete(table, key)
    :ok
  end

  defp version(table, key) do
    case :ets.lookup(table, key) do
      [{^key, _body, version}] -> version
      [] -> nil
    end
  end

  defp listed(key, body, version, true), do: %{key: key, etag: etag(version), body: body}
  defp listed(key, _body, version, false), do: %{key: key, etag: etag(version)}

  defp object(body, version), do: %{body: body, etag: etag(version)}

  defp etag(version), do: Integer.to_string(version)
end
