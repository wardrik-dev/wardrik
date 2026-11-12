defmodule Wardrik.Test.FailingStore do
  @moduledoc "An ETS store that fails each write under a scope once `fail/2` names it."
  @behaviour Wardrik.Store.Adapter

  alias Wardrik.Store.ETS

  @doc "Builds a store over `Wardrik.Store.ETS` named `name`."
  def new(name),
    do: Wardrik.Store.new(__MODULE__, %{name: name, failing: :ets.new(__MODULE__, [:public])})

  @doc "Fails every write under the scope `scope` from now with `{:error, :unavailable}`."
  def fail(%Wardrik.Store{config: %{failing: failing}}, scope),
    do: true = :ets.insert(failing, {:scope, scope <> ":"})

  @impl true
  def child_spec(%{name: name}), do: ETS.child_spec(name)

  @impl true
  def put(config, path, value, opts),
    do: written(config, path, fn -> ETS.put(config.name, path, value, opts) end)

  @impl true
  def delete(config, path, opts),
    do: written(config, path, fn -> ETS.delete(config.name, path, opts) end)

  @impl true
  def lookup(config, path), do: ETS.lookup(config.name, path)

  @impl true
  def keys(config, prefix), do: ETS.keys(config.name, prefix)

  defp written(%{failing: failing}, path, write) do
    case :ets.lookup(failing, :scope) do
      [{:scope, scope}] ->
        if String.starts_with?(path, scope), do: {:error, :unavailable}, else: write.()

      [] ->
        write.()
    end
  end
end
