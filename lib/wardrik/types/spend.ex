defmodule Wardrik.Spend do
  @moduledoc """
  What an org's agents have spent against one of its ceilings, by the `ceiling`'s name, in its
  period now: its `limit`, what they `spent`, what approvals `granted`, how long it lasts, `per`,
  what the next call does once it's spent, `on_exhausted`, and the day it `starts_over`, `nil` for
  a ceiling in `:total`. See `Wardrik.Ceiling`.
  """

  use Wardrik.Type,
    schema: ["ceilings", "properties", "ceilings", "items"],
    fields: [
      ceiling: "ceiling",
      per: {"per", [:day, :week, :month, :total]},
      on_exhausted: {"on_exhausted", [:ask, :deny, :continue]},
      limit: {"limit", Wardrik.Amount},
      spent: {"spent", Wardrik.Amount},
      granted: {"granted", Wardrik.Amount},
      starts_over: {"starts_over", :date}
    ]
end

defmodule Wardrik.Amount do
  @moduledoc "An amount in US dollars, `usd`, tokens, `tokens`, or both. A limit leaves out what it doesn't limit."

  use Wardrik.Type,
    schema: ["defs", "$defs", "amount"],
    fields: [usd: "usd", tokens: "tokens"]
end
