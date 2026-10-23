defmodule Wardrik.Scope do
  @moduledoc """
  Who acts through Wardrik, and on which: the principal, and the grants the authorizer reads to
  decide what they may do. `Wardrik.as/3` makes one. While an operation runs, it names it too.
  """

  alias Wardrik.Authorizer
  alias WardrikCore.Principal

  @enforce_keys [:wardrik, :principal]
  defstruct [:wardrik, :principal, :operation, grants: []]

  @type t() :: %__MODULE__{
          wardrik: Wardrik.t(),
          principal: Principal.t(),
          operation: WardrikProtocol.operation() | nil,
          grants: term()
        }

  @doc "Returns whether the operation running in `scope` may act on `resource`."
  @spec allows?(t(), String.t()) :: boolean()
  def allows?(%__MODULE__{operation: %{action: action}} = scope, resource),
    do: Authorizer.authorize(scope, action, resource) == :ok
end
