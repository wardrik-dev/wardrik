defmodule Wardrik.Interrupts do
  @moduledoc """
  The operations on what the agents a scope can see wait on.

      {:ok, %{"interrupts" => interrupts}} = Wardrik.Interrupts.list(scope)
  """

  use Wardrik.Operations.Functions, prefix: "interrupts"
end
