defmodule Wardrik.Server.Request do
  @moduledoc """
  An operation for `c:Wardrik.Server.run/1` or `c:Wardrik.Server.stream/1` to run: `operation`,
  with `input`, in `scope`.

      %Wardrik.Server.Request{scope: scope, operation: "agent.read", input: %{"agent" => "agt_01JF8X5RQ2"}}
  """

  @enforce_keys [:scope, :operation, :input]
  defstruct [:scope, :operation, :input]

  @type t() :: %__MODULE__{scope: Wardrik.Scope.t(), operation: String.t(), input: map()}
end
