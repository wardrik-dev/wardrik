defmodule Wardrik.Scope do
  @moduledoc """
  Who acts through a Wardrik, and on which: the Wardrik, by name, the principal, and the grants the
  authorizer reads to decide what they may do. `Wardrik.as/3` makes one, and `Wardrik.grant/2` adds
  to it. A scope a token makes names the `policy` every agent it defines is held to. An agent's scope
  carries the `labels` of what its run had read, which the messages it sends carry too. A scope a
  token makes `expires` when it does. While an operation runs, it names the operation too.
  """

  alias Wardrik.Authorizer
  alias WardrikCore.Principal

  @enforce_keys [:wardrik, :principal]
  defstruct [:wardrik, :principal, :operation, :policy, :expires, grants: [], labels: []]

  @type t() :: %__MODULE__{
          wardrik: atom() | Wardrik.t(),
          principal: Principal.t(),
          operation: WardrikProtocol.operation() | nil,
          grants: term(),
          policy: String.t() | map() | nil,
          expires: DateTime.t() | nil,
          labels: [String.t()]
        }

  @doc "Returns whether the operation running in `scope` may act on `resource`."
  @spec allows?(t(), String.t()) :: boolean()
  def allows?(%__MODULE__{operation: %{action: action}} = scope, resource),
    do: Authorizer.authorize(scope, action, resource) == :ok
end
