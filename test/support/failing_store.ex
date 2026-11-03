defmodule Wardrik.Test.FailingStore do
  @moduledoc "An ETS store that fails each write under a scope once `fail/2` names it."
  @behaviour WardrikStore.Adapter

  @doc "Builds a store over `WardrikStore.ETS` named `name`."
  def new(name),
    do: WardrikStore.new(__MODULE__, %{name: name, failing: :ets.new(__MODULE__, [:public])})

  @doc "Fails every write under the scope `scope` from now with `{:error, :unavailable}`."
  def fail(%WardrikStore{config: %{failing: failing}}, scope),
    do: true = :ets.insert(failing, {:scope, scope <> ":"})

  @doc "Fails every write to a path that starts with `prefix` from now."
  def fail_path(%WardrikStore{config: %{failing: failing}}, prefix),
    do: true = :ets.insert(failing, {:scope, prefix})

  @doc "Lets writes through again."
  def recover(%WardrikStore{config: %{failing: failing}}), do: true = :ets.delete(failing, :scope)

  @impl true
  def child_spec(%{name: name}), do: WardrikStore.ETS.child_spec(name)

  @impl true
  def put(config, path, value, opts),
    do: written(config, path, fn -> WardrikStore.ETS.put(config.name, path, value, opts) end)

  @impl true
  def delete(config, path, opts),
    do: written(config, path, fn -> WardrikStore.ETS.delete(config.name, path, opts) end)

  @impl true
  def lookup(config, path), do: WardrikStore.ETS.lookup(config.name, path)

  @impl true
  def keys(config, prefix), do: WardrikStore.ETS.keys(config.name, prefix)

  defp written(%{failing: failing}, path, write) do
    case :ets.lookup(failing, :scope) do
      [{:scope, scope}] ->
        if String.starts_with?(path, scope), do: {:error, :unavailable}, else: write.()

      [] ->
        write.()
    end
  end
end
