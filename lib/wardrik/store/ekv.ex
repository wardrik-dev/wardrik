defmodule Wardrik.Store.EKV do
  @moduledoc """
  The default `Wardrik.Store`: an `EKV` instance on this node's disk, replicated
  between connected nodes.

      config :wardrik, Wardrik.Store,
        adapter: Wardrik.Store.EKV,
        data_dir: "/var/lib/wardrik",
        cluster_size: 3

  `:data_dir` falls back to `WARDRIK_DATA_DIR`, then to a directory named after
  the node in the user's data directory, `~/.local/share/wardrik` on Linux.
  `:cluster_size` is the number of voting members EKV does quorum arithmetic
  against, falling back to `WARDRIK_CLUSTER_SIZE` and then to 1.

  Over more than one member, EKV keeps serving for up to `:shutdown_barrier`
  milliseconds as its node stops, five seconds by default, while other members
  stopping at the same time write down what they hold, so a cluster stopped
  all at once keeps its quorum until the last of them has. `false` stops at
  once.

  Keys are written as `wardrik/<namespace>/<key>`. A conditional write is an EKV
  compare-and-swap, and a namespace written conditionally once stays that way.

  Every member holds everything, and a write lands once more than half of them
  have it, so a cluster needs a quorum of its nodes connected.
  """

  @behaviour Wardrik.Store

  @name :wardrik_store

  @doc "The name of the EKV instance."
  @spec name() :: atom()
  def name, do: @name

  @impl Wardrik.Store
  def child_spec(opts) do
    Supervisor.child_spec(
      {EKV,
       name: @name,
       data_dir: data_dir(opts),
       cluster_size: cluster_size(opts),
       shutdown_barrier: shutdown_barrier(opts)},
      id: __MODULE__
    )
  end

  @impl Wardrik.Store
  def durable_backend(_opts), do: {DurableServer.Backends.EKVStore, name: @name}

  @impl Wardrik.Store
  def quorum(size), do: div(size, 2) + 1

  @doc """
  Checks that `:data_dir` is a directory this node can write to, or is not
  made yet.
  """
  @impl Wardrik.Store
  def check(opts) do
    dir = data_dir(opts)
    where = "on this node's disk, at #{dir}"

    case File.stat(dir) do
      {:ok, %File.Stat{type: :directory, access: :read_write}} -> {:ok, where}
      {:ok, %File.Stat{type: :directory}} -> {:error, "#{where}, which this node cannot write to"}
      {:ok, %File.Stat{}} -> {:error, "#{where}, which is not a directory"}
      {:error, :enoent} -> {:ok, "#{where}, made as the store starts"}
      {:error, reason} -> {:error, "#{where}: #{:file.format_error(reason)}"}
    end
  end

  @impl Wardrik.Store
  def put(ns, key, value, opts) do
    case EKV.put(@name, path(ns, key), value, put_opts(opts)) do
      :ok -> {:ok, nil}
      {:ok, vsn} -> {:ok, vsn}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl Wardrik.Store
  def get(ns, key, opts),
    do: EKV.get(@name, path(ns, key), Keyword.take(opts, [:consistent, :timeout]))

  @impl Wardrik.Store
  def lookup(ns, key), do: EKV.lookup(@name, path(ns, key))

  @impl Wardrik.Store
  def delete(ns, key, opts) do
    case EKV.delete(@name, path(ns, key), delete_opts(opts)) do
      :ok -> :ok
      {:ok, _vsn} -> :ok
      {:error, :not_found} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp delete_opts(opts) do
    case Keyword.fetch(opts, :if_vsn) do
      {:ok, vsn} -> [if_vsn: vsn, resolve_unconfirmed: true]
      :error -> []
    end
  end

  @impl Wardrik.Store
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
    Keyword.get(opts, :cluster_size) || env_integer("WARDRIK_CLUSTER_SIZE") || 1
  end

  @doc "How long EKV keeps serving for other members as its node stops. See the module options."
  @spec shutdown_barrier(keyword()) :: pos_integer() | false
  def shutdown_barrier(opts \\ []) do
    case Keyword.fetch(opts, :shutdown_barrier) do
      {:ok, barrier} -> barrier
      :error -> if cluster_size(opts) > 1, do: :timer.seconds(5), else: false
    end
  end

  @doc "Where this node's data is written. See the module options."
  @spec data_dir(keyword()) :: String.t()
  def data_dir(opts \\ []) do
    Keyword.get(opts, :data_dir) || System.get_env("WARDRIK_DATA_DIR") ||
      Path.join(:filename.basedir(:user_data, "wardrik"), to_string(node()))
  end

  defp path(ns, key), do: "wardrik/#{ns}/" <> key

  defp put_opts(opts) do
    case Keyword.fetch(opts, :if_vsn) do
      {:ok, vsn} -> [if_vsn: vsn, resolve_unconfirmed: true]
      :error -> []
    end
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
