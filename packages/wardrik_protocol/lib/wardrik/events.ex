defmodule Wardrik.Events do
  @moduledoc """
  Operations on the events of the agents named.

      {:ok, cursor} = Wardrik.Events.head(scope, agents: ["agt_1"])
      {:ok, stream} = Wardrik.Events.stream_list(scope, agents: ["agt_1"], after: cursor)
  """

  use Wardrik.Operations.Functions, prefix: "events"
end
