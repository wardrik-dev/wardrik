defmodule Wardrik.Runner do
  @moduledoc """
  Runs an operation the same way for every surface: it finds it in the catalog, checks the input
  against its schema, asks the authorizer, and calls its handler.
  """

  alias Wardrik.Authorizer
  alias Wardrik.Catalog
  alias Wardrik.Error
  alias Wardrik.Resource
  alias Wardrik.Scope

  @doc "Runs the operation `id` in `scope` with `input`, through the handlers `kind` names."
  @spec run(Scope.t(), String.t(), map(), :handlers | :streams) ::
          {:ok, term()} | {:error, Error.t()}
  def run(%Scope{wardrik: wardrik} = scope, id, input, kind) do
    with {:ok, operation, root} <- operation(wardrik.catalog, id),
         {:ok, handler} <- handler(wardrik.catalog, kind, id),
         {:ok, input} <- validate(input, root),
         :ok <- authorize(scope, operation, input) do
      handler.(%{scope | operation: operation}, input)
    end
  end

  defp operation(catalog, id) do
    case Catalog.fetch(catalog, id) do
      {:ok, {operation, root}} -> {:ok, operation, root}
      :error -> {:error, Error.new(:not_found, "There's no operation #{id}.")}
    end
  end

  defp handler(catalog, kind, id) do
    case Map.fetch(Map.fetch!(catalog, kind), id) do
      {:ok, handler} -> {:ok, handler}
      :error -> {:error, Error.new(:not_supported, "#{id} can't be streamed.")}
    end
  end

  defp validate(input, root) do
    case JSV.validate(input, root) do
      {:ok, input} -> {:ok, input}
      {:error, error} -> {:error, Error.new(:invalid_request, Exception.message(error))}
    end
  end

  defp authorize(scope, %{subject: "agent", action: action}, %{"agent" => id}) do
    {:ok, resource} = Resource.agent(id)
    refused(Authorizer.authorize(scope, action, resource), "agent #{id}")
  end

  defp authorize(scope, %{subject: "deployment", action: action}, _input),
    do: refused(Authorizer.authorize(scope, action, Resource.deployment()), "deployment")

  defp authorize(_scope, %{subject: "agents"}, _input), do: :ok

  defp refused(:ok, _what), do: :ok

  defp refused({:error, :not_found}, what),
    do: {:error, Error.new(:not_found, "There's no #{what}.")}

  defp refused({:error, :forbidden}, what),
    do: {:error, Error.new(:forbidden, "You may not do this to the #{what}.")}
end
