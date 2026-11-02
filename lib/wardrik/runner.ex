defmodule Wardrik.Runner do
  @moduledoc """
  Runs operations the same way for every surface:

    1. Finds the operation in the catalog.
    2. Validates the input against its schema.
    3. Asks the authorizer.
    4. For an owner's operation, checks the org is known. See `Wardrik.Orgs`.
    5. Calls the handler.
  """

  alias Wardrik.Authorizer
  alias Wardrik.Catalog
  alias Wardrik.Error
  alias Wardrik.Instance
  alias Wardrik.Orgs
  alias Wardrik.Scope

  @doc "Runs the operation `id` in `scope`, with its handler (`:handlers`) or stream (`:streams`)."
  @spec run(Scope.t(), String.t(), map(), :handlers | :streams) ::
          {:ok, term()} | {:error, Error.t()}
  def run(%Scope{wardrik: instance} = scope, id, input, kind) do
    catalog = Catalog.new()
    scope = %{scope | wardrik: Instance.fetch!(instance)}

    with {:ok, operation, root} <- operation(catalog, id),
         {:ok, handler} <- handler(catalog, kind, id),
         {:ok, input} <- validate(input, root),
         :ok <- authorize(scope, operation, input),
         :ok <- known(scope, operation, input) do
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

  defp authorize(scope, %{subject: "agent", action: action}, %{"agent" => id}),
    do:
      refused(Authorizer.authorize(scope, action: action, resource: {:agent, id}), "agent #{id}")

  defp authorize(
         %Scope{wardrik: wardrik} = scope,
         %{subject: "deployment", action: action},
         _input
       ),
       do:
         refused(
           Authorizer.authorize(scope,
             action: action,
             resource: {:deployment, wardrik.deployment}
           ),
           "deployment"
         )

  defp authorize(_scope, %{subject: "agents"}, _input), do: :ok
  defp authorize(_scope, %{subject: "hook"}, _input), do: :ok
  defp authorize(_scope, %{subject: "channel"}, _input), do: :ok

  defp authorize(scope, %{subject: "owner", action: action}, %{"owner" => owner} = input) do
    [kind, _verb] = String.split(action, ".")
    named = input["provider"] || input["server"] || input["target"] || input["name"]

    refused(
      Authorizer.authorize(scope,
        action: action,
        resource: {:owner, owner},
        context: %{name: named}
      ),
      "#{kind} of #{owner}"
    )
  end

  defp known(%Scope{wardrik: wardrik}, %{subject: "owner"}, %{"owner" => owner}),
    do: Orgs.known(wardrik, Orgs.org(owner))

  defp known(_scope, _operation, _input), do: :ok

  defp refused(:ok, _what), do: :ok

  defp refused({:error, :not_found}, what),
    do: {:error, Error.new(:not_found, "There's no #{what}.")}

  defp refused({:error, :forbidden}, what),
    do: {:error, Error.new(:forbidden, "You may not do this to the #{what}.")}
end
