defmodule Wardrik.Test.OAuthApps do
  @moduledoc "Resolves the same OAuth apps for everyone, each keyed by its name."
  @behaviour WardrikOAuth.Resolver

  @impl true
  def provider(%{name: name}, apps) do
    case Enum.find(apps, fn {given, _opts} -> to_string(given) == name end) do
      {_given, opts} -> {:ok, WardrikOAuth.Provider.new(name, [key: name] ++ opts)}
      nil -> {:error, :not_found}
    end
  end
end
