if Code.ensure_loaded?(EKV) do
  defmodule WardrikStore.EKV do
    @moduledoc """
    Keeps keys on disk with EKV, copied to each connected node.

        store = WardrikStore.EKV.new(name: :my_app, data_dir: "/var/lib/my_app")
        children = [{WardrikStore, store}]

    Keys sit under `wardrik_store/`, so the store can share an EKV instance with other data.

    Once a key is written with `:if_vsn`, keep writing it that way. EKV refuses an
    unconditional write over it.
    """

    @behaviour WardrikStore.Adapter

    @root "wardrik_store/"

    @doc """
    Builds a store. Starts nothing.

    ## Options

      * `:name` - required. The EKV instance's name.
      * `:cluster_size` - `1` unless set.

    Other options, such as `:data_dir`, are passed to EKV when the store starts.
    """
    @spec new(keyword()) :: WardrikStore.t()
    def new(opts) do
      options = Keyword.put_new(opts, :cluster_size, 1)
      WardrikStore.new(__MODULE__, %{name: Keyword.fetch!(opts, :name), options: options})
    end

    @impl WardrikStore.Adapter
    def child_spec(%{options: options}), do: EKV.child_spec(options)

    @impl WardrikStore.Adapter
    def put(%{name: name}, path, value, opts) do
      case EKV.put(name, @root <> path, value, conditional(opts)) do
        :ok -> {:ok, nil}
        {:ok, vsn} -> {:ok, vsn}
        {:error, reason} -> {:error, reason}
      end
    end

    @impl WardrikStore.Adapter
    def lookup(%{name: name}, path), do: EKV.lookup(name, @root <> path)

    @impl WardrikStore.Adapter
    def delete(%{name: name}, path, opts) do
      case EKV.delete(name, @root <> path, conditional(opts)) do
        :ok -> :ok
        {:ok, _vsn} -> :ok
        {:error, :not_found} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end

    @impl WardrikStore.Adapter
    def keys(%{name: name}, prefix) do
      name
      |> EKV.keys(@root <> prefix)
      |> Enum.map(fn {key, _vsn} -> String.replace_prefix(key, @root, "") end)
    end

    @impl WardrikStore.Adapter
    def versions(%{name: name}, prefix) do
      for {key, vsn} <- EKV.keys(name, @root <> prefix),
          do: {String.replace_prefix(key, @root, ""), vsn}
    end

    defp conditional(opts) do
      case Keyword.fetch(opts, :if_vsn) do
        {:ok, vsn} -> [if_vsn: vsn, resolve_unconfirmed: true]
        :error -> []
      end
    end
  end
end
