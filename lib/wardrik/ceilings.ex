defmodule Wardrik.Ceilings do
  @moduledoc """
  The operations on an org's ceilings, the budgets its agents spend from together: reading what
  they've spent against each.

      Wardrik.Ceilings.list(scope, owner: "acme")
      #=> {:ok, [%Wardrik.Spend{ceiling: "plan", limit: %Wardrik.Amount{usd: 20.0}, ...}]}

  Reading them needs `ceiling.read` on the org's `acme/ceiling`, which a reader has, and approving
  past one needs `ceiling.approve`, which an owner has. See `Wardrik.Ceiling`.
  """

  use Wardrik.Operations.Functions, prefix: "ceilings"
end
