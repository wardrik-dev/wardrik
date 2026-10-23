defmodule Wardrik.Run do
  @moduledoc "One run of an agent: what it answered, how it ended, and what it used and cost."

  use Wardrik.Type,
    schema: ["runs", "properties", "runs", "items"],
    fields: [
      id: "id",
      status: {"status", [:running, :completed, :failed, :cancelled, :waiting]},
      model: "model",
      source: "source",
      error: "error",
      started_at: {"started_at", :datetime},
      finished_at: {"finished_at", :datetime},
      duration_ms: "duration_ms",
      tool_calls: "tool_calls",
      tool_errors: "tool_errors",
      input_tokens: "input_tokens",
      output_tokens: "output_tokens",
      cost_micro_usd: "cost_micro_usd"
    ]
end
