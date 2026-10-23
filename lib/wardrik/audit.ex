defmodule Wardrik.Audit do
  @moduledoc """
  The operations on the deployment's audit.

      {:ok, %{"events" => events, "next" => next}} = Wardrik.Audit.list(scope, %{"limit" => 50})
  """

  use Wardrik.Operations.Functions, prefix: "audit"
end
