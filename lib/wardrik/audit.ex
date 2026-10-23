defmodule Wardrik.Audit do
  @moduledoc """
  The operations on the deployment's audit.

      {:ok, %Wardrik.Page{events: changes, next: next}} = Wardrik.Audit.list(scope, limit: 50)
  """

  use Wardrik.Operations.Functions, prefix: "audit"
end
