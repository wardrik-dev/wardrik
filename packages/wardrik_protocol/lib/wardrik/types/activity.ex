defmodule Wardrik.Activity do
  @moduledoc """
  What an agent is doing now.

    * `:doing` - every tool call running, oldest first, or else the one thing it's doing. Each is
      the protocol's `doing` map.
    * `:since` - when it started.
    * `:pending` - how many messages wait behind it.
  """

  use Wardrik.Type,
    schema: ["defs", "$defs", "activity"],
    fields: [doing: "doing", since: {"since", :datetime}, pending: "pending"]
end
