defmodule Wardrik.Test.FailingStore do
  @moduledoc """
  An ETS store that fails each write under a scope once `fail/2` names it. The scope is kept in
  a store of its own beside it, so it lasts as long as the store, past the test that set it.
  """
  @behaviour Wardrik.Store.Adapter

  alias Wardrik.Store.ETS

  @doc "Builds a store over `Wardrik.Store.ETS` named `name`."
  def new(name),
    do: Wardrik.Store.new(__MODULE__, %{name: name, failing: :"#{name} failing"})

  @doc "Fails every write under the scope `scope` from now with `{:error, :unavailable}`."
  def fail(%Wardrik.Store{config: %{failing: failing}}, scope),
    do: {:ok, _vsn} = ETS.put(failing, "scope", scope <> ":", [])

  @impl true
  def child_spec(%{name: name, failing: failing}) do
    stores = [ETS.child_spec(name), ETS.child_spec(failing)]
    opts = [strategy: :one_for_all, name: :"#{name} stores"]
    %{id: name, type: :supervisor, start: {Supervisor, :start_link, [stores, opts]}}
  end

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
    case ETS.lookup(failing, "scope") do
      {scope, _vsn} ->
        if String.starts_with?(path, scope), do: {:error, :unavailable}, else: write.()

      nil ->
        write.()
    end
  end
end
