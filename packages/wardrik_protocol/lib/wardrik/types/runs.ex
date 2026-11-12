defmodule Wardrik.Runs do
  @moduledoc "An agent's `runs`, newest first, and their `totals`."

  use Wardrik.Type,
    schema: ["runs"],
    fields: [
      runs: {"runs", [Wardrik.Run]},
      totals: {"totals", Wardrik.Runs.Totals},
      cursor: "cursor"
    ]
end

defmodule Wardrik.Runs.Totals do
  @moduledoc "Totals across an agent's runs."

  use Wardrik.Type,
    schema: ["runs", "properties", "totals"],
    fields: [
      runs: "runs",
      failed: "failed",
      tool_calls: "tool_calls",
      input_tokens: "input_tokens",
      output_tokens: "output_tokens",
      cost_micro_usd: "cost_micro_usd",
      last_at: {"last_at", :datetime}
    ]
end
