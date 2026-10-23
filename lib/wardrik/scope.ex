defmodule Wardrik.Scope do
  @moduledoc """
  Who acts through a Wardrik, and on which: the Wardrik, by name, the principal, and the grants the
  authorizer reads to decide what they may do. `Wardrik.as/3` makes one, and `Wardrik.grant/2` adds
  to it. A scope a token makes names the `policy` every agent it defines is held to. While an
  operation runs, it names the operation too.
  """

  alias Wardrik.Authorizer
  alias WardrikCore.Principal

  @enforce_keys [:wardrik, :principal]
  defstruct [:wardrik, :principal, :operation, :policy, grants: []]

  @type t() :: %__MODULE__{
          wardrik: atom() | Wardrik.t(),
          principal: Principal.t(),
          operation: WardrikProtocol.operation() | nil,
          grants: term(),
          policy: String.t() | nil
        }

  @doc "Returns whether the operation running in `scope` may act on `resource`."
  @spec allows?(t(), String.t()) :: boolean()
  def allows?(%__MODULE__{operation: %{action: action}} = scope, resource),
    do: Authorizer.authorize(scope, action, resource) == :ok
end
