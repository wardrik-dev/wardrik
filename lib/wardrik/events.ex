defmodule Wardrik.Events do
  @moduledoc """
  The operations on the events of the agents a scope can see.

      {:ok, cursor} = Wardrik.Events.head(scope)
      {:ok, stream} = Wardrik.Events.stream_list(scope, after: cursor)
  """

  use Wardrik.Operations.Functions, prefix: "events"
end
