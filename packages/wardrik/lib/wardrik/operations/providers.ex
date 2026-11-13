defmodule Wardrik.Operations.Providers do
  @moduledoc false

  # An owner's OAuth apps. See `Wardrik.OAuth.Apps`.

  alias Wardrik.Error
  alias Wardrik.OAuth.Apps
  alias Wardrik.Scope

  @doc "Lists the owner's OAuth apps, never a client secret."
  @spec list(Scope.t(), map()) :: {:ok, map()}
  def list(%Scope{wardrik: wardrik}, %{"owner" => owner}),
    do: {:ok, %{"providers" => Apps.list(wardrik, owner)}}

  @doc "Adds an OAuth app for the owner."
  @spec add(Scope.t(), map()) :: {:ok, map()} | {:error, Error.t()}
  def add(scope, %{"owner" => owner} = input),
    do: Apps.add(scope, owner, Map.delete(input, "owner"))

  @doc "Removes one of the owner's OAuth apps."
  @spec remove(Scope.t(), map()) :: {:ok, map()} | {:error, Error.t()}
  def remove(scope, %{"owner" => owner, "name" => name}), do: Apps.remove(scope, owner, name)
end
