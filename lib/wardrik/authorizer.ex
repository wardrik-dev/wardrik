defmodule Wardrik.Authorizer do
  @moduledoc """
  An authorizer decides whether a scope may take an action on a resource. Wardrik asks it once for
  each operation, and for each agent an operation over many covers.

  It answers `{:error, :not_found}` where nothing the scope holds reaches the resource, so a caller
  learns nothing of what it can't see, and `{:error, :forbidden}` where it reaches it without the
  action. `Wardrik.Statements` is the one Wardrik uses unless told otherwise.
  """

  alias Wardrik.Scope

  @doc "Decides whether `scope` may take `action`, like `agent.ask`, on `resource`."
  @callback authorize(config :: term(), Scope.t(), action :: String.t(), resource :: String.t()) ::
              :ok | {:error, :forbidden | :not_found}

  @doc "Asks `scope`'s authorizer whether it may take `action` on `resource`."
  @spec authorize(Scope.t(), String.t(), String.t()) :: :ok | {:error, :forbidden | :not_found}
  def authorize(%Scope{wardrik: %{authorizer: {module, config}}} = scope, action, resource),
    do: module.authorize(config, scope, action, resource)
end
