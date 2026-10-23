defmodule Wardrik.Decision do
  @moduledoc "A call decided, by its `id`: `:approved` or `:rejected`."

  use Wardrik.Type,
    schema: ["decided", "properties", "decisions", "items"],
    fields: [id: "id", decision: {"decision", [:approved, :rejected]}]
end
