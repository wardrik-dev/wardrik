defmodule Wardrik.Interrupts do
  @moduledoc """
  Operations on the calls waiting on a person, across every agent the scope can see.

      Wardrik.Interrupts.list(scope)
      #=> {:ok, [%Wardrik.Interrupt{id: "call_1", agent: "agt_1", reason: :tool_approval, ...}]}
  """

  use Wardrik.Operations.Functions, prefix: "interrupts"
end
