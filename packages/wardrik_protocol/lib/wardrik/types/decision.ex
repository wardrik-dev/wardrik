defmodule Wardrik.Decision do
  @moduledoc "A decided call: its `id`, and its `decision`, `:approved` or `:rejected`."

  use Wardrik.Type,
    schema: ["decided", "properties", "decisions", "items"],
    fields: [id: "id", decision: {"decision", [:approved, :rejected]}]
end
