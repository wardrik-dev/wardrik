defmodule Wardrik.Activity do
  @moduledoc """
  What an agent is doing now, since when, and how many messages wait behind it. `doing` is every
  tool call running, oldest first, or the one thing it's doing otherwise, each as the protocol's
  `doing` map.
  """

  use Wardrik.Type,
    schema: ["defs", "$defs", "activity"],
    fields: [doing: "doing", since: {"since", :datetime}, pending: "pending"]
end
