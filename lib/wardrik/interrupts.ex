defmodule Wardrik.Interrupts do
  @moduledoc """
  The operations on what the agents a scope can see wait on.

      {:ok, [%Wardrik.Interrupt{agent_id: agent_id, id: id} | _rest]} = Wardrik.Interrupts.list(scope)
  """

  use Wardrik.Operations.Functions, prefix: "interrupts"
end
