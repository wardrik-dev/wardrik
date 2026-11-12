defmodule WardrikTriggers.Test.FailingStore do
  @moduledoc "An ETS store that fails a write once `fail_on/2` says which one."
  @behaviour WardrikStore.Adapter

  @doc "Builds a store over `WardrikStore.ETS` named `name`."
  def new(name),
    do: WardrikStore.new(__MODULE__, %{name: name, writes: :atomics.new(2, signed: false)})

  @doc "Fails the `n`th write from now with `{:error, :unavailable}`. `0` fails none."
  def fail_on(%WardrikStore{config: %{writes: writes}}, n) do
    :atomics.put(writes, 1, 0)
    :atomics.put(writes, 2, n)
  end

  @impl true
  def child_spec(%{name: name}), do: WardrikStore.ETS.child_spec(name)

  @impl true
  def put(config, path, value, opts),
    do: written(config, fn -> WardrikStore.ETS.put(config.name, path, value, opts) end)

  @impl true
  def delete(config, path, opts),
    do: written(config, fn -> WardrikStore.ETS.delete(config.name, path, opts) end)

  @impl true
  def lookup(config, path), do: WardrikStore.ETS.lookup(config.name, path)

  @impl true
  def keys(config, prefix), do: WardrikStore.ETS.keys(config.name, prefix)

  defp written(%{writes: writes}, write) do
    if :atomics.add_get(writes, 1, 1) == :atomics.get(writes, 2),
      do: {:error, :unavailable},
      else: write.()
  end
end
