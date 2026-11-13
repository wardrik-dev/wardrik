defmodule Wardrik.NotifyTargets do
  @moduledoc """
  Operations on the webhooks an owner keeps for their agents' notices.

      Wardrik.NotifyTargets.add(scope, "acme", name: "ops", url: "https://hooks.acme.example/wardrik")
      #=> {:ok, %Wardrik.NotifyTarget{owner: "acme", name: "ops", ...}}

  Your resolver gives each agent the targets it routes to. Routing to another owner's is
  `notify_target.use` on `{:notify_target, owner}`, as your authorizer decides.
  """

  use Wardrik.Operations.Functions, prefix: "notify_targets"
end
