defmodule Wardrik.Call do
  @moduledoc "A tool call an agent is running: its `id`, the tool's `name`, and how long it has run."

  use Wardrik.Type,
    schema: ["calls", "properties", "calls", "items"],
    fields: [id: "id", name: "name", elapsed_ms: "elapsed_ms"]
end
