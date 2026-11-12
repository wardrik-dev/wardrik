defmodule Wardrik.OAuth.Test.Fixed do
  @moduledoc "Resolves the same providers for every principal, each keyed `fixed/name`."
  @behaviour Wardrik.OAuth.Resolver

  @impl true
  def provider(%{name: name}, providers) do
    case Enum.find(providers, fn {given, _opts} -> to_string(given) == name end) do
      {_given, opts} ->
        {:ok, Wardrik.OAuth.Provider.new(name, [key: "fixed/" <> name] ++ opts)}

      nil ->
        {:error, :not_found}
    end
  end
end

defmodule Wardrik.OAuth.Test.Apps do
  @moduledoc "Resolves each principal's providers as the test set them, in an `Agent`."
  @behaviour Wardrik.OAuth.Resolver

  @impl true
  def provider(%{name: name, principal: principal}, apps) do
    Agent.get(apps, fn set ->
      send(set.test, {:resolved, name, principal.id})
      Map.get(set, {principal.id, name}, {:error, :not_found})
    end)
  end
end
