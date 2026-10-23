defmodule Wardrik.Interrupts do
  @moduledoc """
  The operations on what the agents a scope can see wait on.

      Wardrik.Interrupts.list(scope)
      #=> {:ok, [%Wardrik.Interrupt{id: "call_1", agent_id: "acme/books", reason: :tool_approval, ...}]}
  """

  use Wardrik.Operations.Functions, prefix: "interrupts"
end
