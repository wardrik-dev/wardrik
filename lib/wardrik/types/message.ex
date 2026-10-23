defmodule Wardrik.Message do
  @moduledoc "A message sent to an agent, by its `id`, and the `cursor` its answer comes after."

  use Wardrik.Type,
    schema: ["asked", "properties", "message"],
    fields: [id: "id", cursor: "cursor"]
end
