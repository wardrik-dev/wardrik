defmodule Tars.Store.EKV do
  @moduledoc """
  The default `Tars.Store`: an `EKV` instance on this node's disk, replicated
  between connected nodes.

      config :tars, Tars.Store,
        adapter: Tars.Store.EKV,
        data_dir: "/var/lib/tars",
        cluster_size: 3

  `:data_dir` falls back to `TARS_DATA_DIR`, then to a directory named after
  the node in the user's data directory, `~/.local/share/tars` on Linux.
  `:cluster_size` is the number of voting members EKV does quorum arithmetic
  against, falling back to `TARS_CLUSTER_SIZE` and then to 1.

  Keys are written as `tars/<namespace>/<key>`. A conditional write is an EKV
  compare-and-swap, and a namespace written conditionally once stays that way.
  """

  @behaviour Tars.Store

  @name :tars_store

  @doc "The name of the EKV instance."
  @spec name() :: atom()
  def name, do: @name

  @impl Tars.Store
  def child_spec(opts) do
    Supervisor.child_spec(
      {EKV, name: @name, data_dir: data_dir(opts), cluster_size: cluster_size(opts)},
      id: __MODULE__
    )
  end

  @impl Tars.Store
  def durable_backend(_opts), do: {DurableServer.Backends.EKVStore, name: @name}

  @impl Tars.Store
  def put(ns, key, value, opts) do
    case EKV.put(@name, path(ns, key), value, put_opts(opts)) do
      :ok -> {:ok, nil}
      {:ok, vsn} -> {:ok, vsn}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl Tars.Store
  def get(ns, key, opts), do: EKV.get(@name, path(ns, key), Keyword.take(opts, [:consistent]))

  @impl Tars.Store
  def lookup(ns, key), do: EKV.lookup(@name, path(ns, key))

  @impl Tars.Store
  def delete(ns, key) do
    case EKV.delete(@name, path(ns, key)) do
      :ok -> :ok
      {:ok, _vsn} -> :ok
      {:error, :not_found} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl Tars.Store
  def keys(ns, prefix) do
    root = path(ns, "")

    for entry <- EKV.keys(@name, root <> prefix),
        key = entry |> written_key() |> String.replace_prefix(root, ""),
        key != "",
        do: key
  end

  @doc "How many voting members EKV does quorum arithmetic against."
  @spec cluster_size(keyword()) :: pos_integer()
  def cluster_size(opts \\ []) do
    Keyword.get(opts, :cluster_size) || env_integer("TARS_CLUSTER_SIZE") || 1
  end

  @doc "Where this node's data is written. See the module options."
  @spec data_dir(keyword()) :: String.t()
  def data_dir(opts \\ []) do
    Keyword.get(opts, :data_dir) || System.get_env("TARS_DATA_DIR") ||
      Path.join(:filename.basedir(:user_data, "tars"), to_string(node()))
  end

  defp path(ns, key), do: "tars/#{ns}/" <> key

  defp put_opts(opts) do
    Enum.flat_map(opts, fn
      {:if_vsn, vsn} -> [if_vsn: vsn, resolve_unconfirmed: true]
      {:ttl_ms, ms} -> [ttl: ms]
    end)
  end

  defp written_key({key, _vsn}) when is_binary(key), do: key
  defp written_key(key) when is_binary(key), do: key

  defp env_integer(name) do
    with value when is_binary(value) <- System.get_env(name),
         {integer, ""} <- Integer.parse(value) do
      integer
    else
      _other -> nil
    end
  end
end
