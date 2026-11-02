defmodule Wardrik.Hook do
  @moduledoc """
  Delivers a service's request to an agent's webhook trigger.

      :ok = Wardrik.Hook.deliver(scope,
        agent: "agt_01JF8X5RQ2",
        trigger: "issues",
        body: body,
        headers: headers
      )
  """

  use Wardrik.Operations.Functions, prefix: "hook"
end
