defmodule Wardrik.Runner do
  @moduledoc false

  alias Wardrik.Authorizer
  alias Wardrik.Catalog
  alias Wardrik.Error
  alias Wardrik.Instance
  alias Wardrik.Scope

  @held ~w(secret provider mcp_server)

  @doc "Runs the operation `id` in `scope`, with its handler."
  @spec run(Scope.t(), String.t(), map()) :: {:ok, term()} | {:error, Error.t()}
  def run(scope, id, input), do: ran(scope, id, input, :handlers)

  @doc "Streams the operation `id` in `scope`, or returns `not_supported`."
  @spec stream(Scope.t(), String.t(), map()) :: {:ok, Enumerable.t()} | {:error, Error.t()}
  def stream(scope, id, input), do: ran(scope, id, input, :streams)

  defp ran(%Scope{wardrik: instance} = scope, id, input, kind) do
    catalog = Catalog.new()
    scope = %{scope | wardrik: Instance.fetch!(instance)}

    with {:ok, operation, root} <- operation(catalog, id),
         {:ok, handler} <- handler(catalog, kind, id),
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

  # A conversation is its agent's: its operations are authorized on the agent.
  defp authorize(scope, %{subject: "agent", action: action}, %{"agent" => id} = input) do
    context = if input["conversation"], do: %{conversation: input["conversation"]}, else: %{}

    refused(
      Authorizer.authorize(scope, action: action, resource: {:agent, id}, context: context),
      "agent #{id}"
    )
  end

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

  # What an owner holds is authorized on the owner, named as the caller names it. Wardrik never
  # reads it: the authorizer decides who may act for it.
  defp authorize(scope, %{subject: kind, action: action}, %{"owner" => owner})
       when kind in @held do
    resource = {String.to_existing_atom(kind), owner}

    refused(
      Authorizer.authorize(scope, action: action, resource: resource),
      "#{kind} of #{owner}"
    )
  end

  # A principal's connections are their own.
  defp authorize(scope, %{subject: "connection", action: action}, _input) do
    resource = {:connection, scope.principal.id}
    refused(Authorizer.authorize(scope, action: action, resource: resource), "connections")
  end

  defp authorize(_scope, %{subject: "agents"}, _input), do: :ok
  defp authorize(_scope, %{subject: "hook"}, _input), do: :ok
  defp authorize(_scope, %{subject: "channel"}, _input), do: :ok

  defp refused(:ok, _what), do: :ok

  defp refused({:error, :not_found}, what),
    do: {:error, Error.new(:not_found, "There's no #{what}.")}

  defp refused({:error, :forbidden}, what),
    do: {:error, Error.new(:forbidden, "You may not do this to the #{what}.")}
end
