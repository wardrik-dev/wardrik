defmodule Wardrik.Page do
  @moduledoc "A page of events, and `next`, where to read on from."

  use Wardrik.Type,
    schema: ["events"],
    fields: [events: {"events", [Wardrik.Event]}, next: "next"]
end
