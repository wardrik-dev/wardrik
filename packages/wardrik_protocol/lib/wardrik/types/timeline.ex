defmodule Wardrik.Timeline do
  @moduledoc """
  An agent's conversation as a person reads it, oldest first.

  Each of `items` is the protocol's map of a message (`kind` `"user"`) or of a run with its steps
  (`kind` `"run"`).
  """

  use Wardrik.Type, schema: ["timeline"], fields: [items: "items", cursor: "cursor"]
end
